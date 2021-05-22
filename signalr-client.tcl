## signalr.tcl (created by Tloona here)

package require http 2.9.0
package require tls 1.7
package require websocket 1.4
package require tclooh 2.0.0
package require rl_json 0.9.9

namespace import ::rl_json::json

namespace eval signalr {
    namespace export client hub
}

proc ::signalr::init-tls {} {
    tls::init -autoservername yes
    ::http::register https 443 ::tls::socket
}

##
::ooh::class create ::signalr::hub {
    
    property connection {}
    property name ""
    
    construct {args} {
        my configure {*}$args
    }
    
    method invoke {method argsData} {
        set invocationId [$connection invocationId [self]]
        set message [json template {
            {
                "H": "~S:hub",
                "M": "~S:method",
                "A": "~T:args",
                "I": "~N:invocation"
            }
        } [list hub $name method $method args $argsData \
                invocation $invocationId]]
        $connection send $message
        return $invocationId
    }

    method result {invocationId result} {
        puts "Result of invocation $invocationId : $result"
    }

    method progress {invocationId data} {
        puts "Progress of invocation $invocationId : $data"
    }

    method error {invocationId message data} {
        set m "Error occured on invocation $invocationId"
        append m ": $message (additional data: $data)"
        puts $m
    }

    method huberror {invocationId message data} {
        set m "Hub-Error occured on invocation $invocationId"
        append m ": $message (additional data: $data)"
        puts $m
    }

}

::ooh::class create ::signalr::client {
    
    property Url {}
    
    property Hubs {}
    
    property Handshake {} -get
    property Socket {}
    property Connected no -get
    property Started no -get
    property InvocationId 0
    property Invocations {}
    
    construct {args} {
        set Url [dict get $args -url]
        if {[dict exist $args -hubs]} {
            foreach {hub} [dict get $args -hubs] {
                my addHub $hub
            }
        }
    }
    
    destructor {
        my stop
        if {$Handshake != {}} {
            $Handshake destroy
        }
    }
    
    method addHub {hub} {
        set name [string tol [$hub cget -name]]
        if {![dict exists $Hubs $name]} {
            if {$Socket != {}} {
                throw SIGNALR "Cannot create new hub, Connection [self] is already started"
            }
            $hub configure -connection [self]
            dict set Hubs $name $hub
        }
        my hub $name
    }
    
    method hub {name args} {
        set hub [dict get $Hubs $name]
        if {$args != {}} {
            $hub {*}$args
        } else {
            set hub
        }
    }
    
    method invocationId {hub} {
        set iid [incr InvocationId]
        dict set Invocations $iid $hub
        return $iid
    }

    method start {} {
        if {$Hubs == {}} {
            throw SIGNALR "No hubs registered in connection! Use addHub to add one."
        }
        if {$Handshake == {}} {
            set Handshake [::signalr::Handshake new $Url [lindex $Hubs 0]]
        }
        set Socket [::websocket::open [$Handshake connectUrl] [list [self] handleSocket]]
    }
    
    method stop {} {
        if {$Socket != {}} {
            try {
                ::websocket::close $Socket
            } trap {WEBSOCKET} {msg} {
                # we don't care much
            }
            set Socket {}
            set Started no
            set Connected no
        }
    }
    
    method send {message} {
        ::websocket::send $Socket text $message
    }
    
    method handleSocket {sock type message} {
        switch -nocase -glob -- $type {
            conn* {
                my SetConnected yes
            }
            te* {
                if {$message == {} || $message == {{}}} {
                    return
                }
                my ParseAndProcessMessage $message
            }
            cl* -
            disc* {
                my SetStarted no
                my SetConnected no
            }
        }
    }

    ## Parse and process messages received from the server.
    # Messages are usually json, but sometimes there is more than one json
    # string in one message. Then they are not separated by some char, e.g.
    # they look like
    #
    # {"C":"...","G":"..."}{"R":"...","I:"."}
    #
    # Job of this method is to split such messages up into several json
    # objects that can be processed.
    method ParseAndProcessMessage {message} {
        set idx [string first "\{" $message 1]
        set jdx 0
        while {$idx >= 0} {
            set prevIdx [expr {$idx - 1}]
            if {[string index $message $prevIdx] ne "\}"} {
                # some object opening char within a message
                set idx [string first "\{" $message [incr idx]]
                continue
            }

            my ProcessMessage [string range $message $jdx $prevIdx]

            set jdx $idx
            set idx [string first "\{" $message [incr idx]]
        }

        my ProcessMessage [string range $message $jdx end]
    }

    method SetConnected {isConnected} {
        set Connected $isConnected
    }

    method SetStarted {isStarted} {
        set Started $isStarted
    }

    method ProcessMessage {message} {
        set msg [json get $message]

        if {[dict exists $msg I]} {
            # invocation received from server
            my ProcessInvocationResult $msg
            return
        }

        set crtlResult [my ProcessControlFields $msg]
        if {[dict exist $msg M]} {
            # a list of method calls. Save the message ID too for evtl reconnect.
            if {[dict exists $msg C]} {
                $Handshake setMessageId [dict get $msg C]
            }
            foreach {method} [dict get $msg M] {
                my ProcessHubMethod $method
            }
        }

        # process the control result
        if {[dict get $crtlResult disconnect]} {
            my stop
        }
        if {[dict get $crtlResult reconnect]} {
            my stop
            my start
        }
    }

    method ProcessInvocationResult {msg} {
        set invocId [dict get $msg I]
        if {![dict exists $Invocations $invocId]} {
            return
        }

        set hub [dict get $Invocations $invocId]
        dict unset Invocations $invocId
        if {[dict exists $msg E]} {
            # error message
            if {[dict exists $msg H] && [dict get $msg H]} {
                $hub huberror $invocId [dict get $msg E] \
                    [expr {[dict exists $msg D] ? [dict get $msg D] : {}}]
            } else {
                $hub error $invocId [dict get $msg E] \
                    [expr {[dict exists $msg D] ? [dict get $msg D] : {}}]
            }
        } else {
            # result message
            $hub result $invocId \
                [expr {[dict exists $msg R] ? [dict get $msg R] : {}}]
        }
    }

    method ProcessControlFields {msg} {
        set result {disconnect no reconnect no}
        if {[dict exists $msg D] && [dict get $msg D]} {
            # disconnect event received from server
            return [list disconnect yes]
        }
        if {[dict exists $msg T] && [dict get $msg T]} {
            dict set result reconnect yes
        }
        if {[dict exists $msg G]} {
            $Handshake setGroupsToken [dict get $msg G]
        }

        if {[dict exist $msg S] && [dict get $msg S]} {
            # start message received
            my SetStarted yes
        }
        if {[dict exists $msg G]} {
            $Handshake setGroupsToken [dict get $msg G]
        }

        return $result
    }

    method ProcessHubMethod {methodCall} {
        if {[dict exists $methodCall P]} {
            # a progress message
            set prgInfo [dict get $methodCall P]
            set invocId [dict get $prgInfo I]
            if {[dict exists $Invocations $invocId]} {
                set hub [dict get $Invocations $invocId]
                $hub progress $invocId [dict get $prgInfo D]
            }
        } elseif {[dict exists $methodCall H]} {
            # a hub method
            set hub [string tol [dict get $methodCall H]]
            if {[dict exists $Hubs $hub]} {
                my hub $hub [dict get $methodCall M] {*}[dict get $methodCall A]
            }
        }
    }
}

::ooh::class create ::signalr::Handshake {

    property PROTOCOL_VERSION 1.5

    property Url {}
    property ConnectionData {} -get

    property Headers {} -get

    # properties set from the negotiate socket conf data
    property ConnectionToken {} -get
    property ConnectionId {} -get
    property KeepAliveTimeout {} -get
    property DisconnectTimeout {} -get
    property ConnectionTimeout {} -get
    property TryWebSockets {} -get
    property ProtocolVersion {} -get
    property TransportConnectTimeout {} -get
    property LongPollDelay {} -get

    # properties set from the connection, used for reconnect
    property GroupsToken {} -get -set
    property MessageId {} -get -set

    construct {url hub} {
        set Url [my NormalizeUrl $url]
        set ConnectionData [my GetConnectionData $hub]
        my Negotiate
    }

    method connectUrl {} {
        regexp {^(https?)://} $Url m scheme
        set wsUrl [if {[string match *s $scheme]} {
            regsub ^$scheme $Url wss
        } else {
            regsub ^$scheme $Url ws
        }]

        append wsUrl / connect ? [my SocketUrlQuery]
    }

    method SocketUrlQuery {} {
        set queryString [http::formatQuery transport webSockets \
                                           connectionToken $ConnectionToken \
                                           connectionData $ConnectionData \
                                           clientProtocol $ProtocolVersion]
        foreach {key} {GroupsToken MessageId} {
            if {[set $key] != {}} {
                append queryString & [http::formatQuery $key [set $key]]
            }
        }
        return $queryString
    }

    method Negotiate {} {
        append url $Url / negotiate
        append url ? [http::formatQuery connectionData $ConnectionData clientProtocol 1.5]
        set socketConf [my CallManagementUrl $url]
        foreach {key val} [dict filter $socketConf script {k v} {expr {![string match Url $k]}}] {
            set $key [dict get $socketConf $key]
        }
    }

    method start {} {
        append url $Url / start ? [my SocketUrlQuery]
        my CallManagementUrl $url
    }

    method CallManagementUrl {mgmtUrl} {
        set httpToken {}
        try {
            set hostName [lindex [split [lindex [split $Url /] 2] :] 0]
            set httpToken [http::geturl $mgmtUrl -keepalive yes -headers [list Host $hostName]]
            if {[::http::ncode $httpToken] != 200} {
                throw SIGNALR "Error while calling $mgmtUrl : \[[::http::code $httpToken]\]"
            }
            json get [::http::data $httpToken]
        } finally {
            if {$httpToken != {}} {
                ::http::cleanup $httpToken
            }
        }
    }

    method GetConnectionData {hub} {
        json template {[{"name": "~S:hub"}]} [list hub $hub]
    }

    method NormalizeUrl {url} {
        if {[string match */ $url]} {
            string replace $url end end
        } else {
            set url
        }
    }
}

::signalr::init-tls

package provide signalr::client 1.0.0
