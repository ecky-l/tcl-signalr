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
        set message [json template {
            {
                "H": "~S:hub",
                "M": "~S:method",
                "A": "~T:args",
                "I": "~N:incr"
            }
        } [list hub $name method $method args $argsData incr [$connection incr]]]
        $connection send $message
    }
    
}

::ooh::class create ::signalr::client {
    
    property Url {}
    
    property Hubs {}
    
    property Handshake {} -get
    property Socket {}
    property Connected no -get
    property Started no -get
    property Increment 0
    
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
        set name [$hub cget -name]
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
    
    method incr {} {
        incr Increment
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
            ::websocket::close $Socket
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
                if {[regexp {({.+})({.+})} $message m part1 part2]} {
                    # a control message with a result
                    my ProcessMessage $part1 $part2
                } else {
                    my ProcessMessage $message
                }
            }
            cl* -
            disc* {
                my SetStarted no
                my SetConnected no
            }
        }
    }

    method SetConnected {isConnected} {
        set Connected $isConnected
    }

    method SetStarted {isStarted} {
        set Started $isStarted
    }

    method ProcessMessage {message {result {}}} {
        set msg [json get $message]
        if {[dict exists $msg C]} {
            $Handshake setMessageId [dict get $msg C]
        }
        if {[dict exist $msg S] && [dict get $msg S]} {
            # start message received
            my SetStarted yes
            return
        }
        if {[dict exists $msg G]} {
            $Handshake setGroupsToken [dict get $msg G]
        }

        if {[dict exist $msg M]} {
            # a method call to us
            my ProcessHubMethod [lindex [dict get $msg M]  0]
        }
    }

    method ProcessHubMethod {methodCall} {
        if {[dict exists $methodCall H]} {
            # a hub method
            set hub [string tol [dict get $methodCall H]]
            if {[dict exists $Hubs $hub]} {
                my hub $hub [dict get $methodCall M] [dict get $methodCall A]
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
