## signalr.tcl (created by Tloona here)

package require http 2.9.0
package require tls 1.7
package require websocket 1.4
package require tclooh 1.0.0
package require rl_json 0.9.9

namespace import ::rl_json::json

namespace eval signalr {
    namespace export client hub
}

proc ::signalr::init-tls {} {
    tls::init -autoservername yes
    ::http::register https 443 ::tls::socket
}

## Connection hub
#
# The signalr protocol supports the concept of "Hubs". A hub is kindof an endpoint at either
# the server or the client, where method calls can be directed to. A method call consists of
# a method name and a list of arguments. The hub is plugged into the connection and the
# connection references it whenever calls to it are made or results of previous calls are sent.
#
# This class represents the a hub on the client side. It is meant as an abstract base class.
# To use it, derive a class from it and define in the derived class the methods that can be
# called from the server. Override the methods [result], [progress], [error] and [huberror]
# to implement specific behaviour for your hub on receiving results, progress, errors or
# huberrors. The callback methods must be public, that means they must start with lowercase
# letters. If a hub method is received with first letter in upper case, the connection turns
# that first letter into lower case before calling the method.
::ooh::class create ::signalr::hub {
    
    property connection {}
    property name ""
    
    construct {args} {
        my configure {*}$args
    }
    
    ## invokes a method on the server with this hub as target.
    #
    # Results, errors and progress is received for this hub. If the side
    # effect is that the server calls methods on this hub, they must be
    # implemented correspondingly as methods in the subclass of this class.
    method invoke {method argsData} {
        if {![$connection getStarted]} {
            throw SIGNALR "Cannot invoke $method from hub [self], SignalR Connection not fully established!"
        }
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

    ## Called when invocation results arrive from the server.
    #
    # Override this with your special implementation.
    method result {invocationId result} {
        puts "Result of invocation $invocationId : $result"
    }

    ## Called when invocation progress arrives from the server.
    #
    # Override this with your special implementation.
    method progress {invocationId data} {
        puts "Progress of invocation $invocationId : $data"
    }

    ## Called when an invocation results in an error from the server.
    #
    # Override this with your special implementation.
    method error {invocationId message data} {
        set m "Error occured on invocation $invocationId"
        append m ": $message (additional data: $data)"
        puts $m
    }

    ## Called when an invocation results in a hub error.
    #
    # The protocol distinguishes between general errors and hub errors.
    # This method is called on hub errors.
    # Override this with your special implementation.
    method huberror {invocationId message data} {
        set m "Hub-Error occured on invocation $invocationId"
        append m ": $message (additional data: $data)"
        puts $m
    }

}

## SignalR client implementation
#
# This class represents the signalr client. A good description of the flow for connecting a
# client to a signalr server can be found here:
#
# https://blog.3d-logic.com/2015/03/29/signalr-on-the-wire-an-informal-description-of-the-signalr-protocol/
#
# Principally there are two steps:
# * A call to a REST service with parameters to negotiate the socket configuration.
# * The actual call to open the websocket (or other transport, but is not implemented here), using
#   parameters from the socket configuration retrieved from the REST call before.
#
# The negotiating and parameters management is done with an object of the Handshake class (see
# below). The client instantiates a Handshake object at [start] and uses the socket url, which is
# returned from Handshake, to instantiate the connection. Once the connection is alive, it can be
# used to send invocations from the configured hubs. Responses and method invocations on the client
# are parsed and forwarded to the respective hubs.
::ooh::class create ::signalr::client {

    ## The signalr URL. Typically has path /signalr
    property Url {}

    ## Dictionary of hubs by their name. Names are all lowercase.
    property Hubs {}

    ## Handshake object for websocket configuration connect and reconnect.
    property Handshake {} -get

    ## The actual websocket object when the client is connected.
    property Socket {}

    ## Indicates whether the client is connected.
    property Connected no -get

    ## Indicates whether the client is started, (it has received the init message from the server)
    property Started no -get

    ## Current incovationID. Is incremented when retrieved.
    property InvocationId 0

    ## Dictionary of invocation IDs to hubs, for managing results.
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

    ## Adds a hub to the client.
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

    ## Get a hub by its name from the dict of Hubs.
    #
    # Can also be used to call methods on the hub, when the method name and args
    # are in the $args array
    method hub {name args} {
        set hub [dict get $Hubs $name]
        if {$args != {}} {
            $hub {*}$args
        } else {
            set hub
        }
    }

    ## Generates a unique invocation ID and links the hub to it.
    #
    # The invocation ID is added to a method invocation on the server (see [hub invoke])
    # and sent from the server in responses, errors or progress messages regarding the
    # invocation with that ID. When a response-, error- or progress message is received,
    # the client can call the corresponding methods in the hub which generated the
    # invocation. Consequently this method is called from hubs to retrieve an invocation
    # ID when invoking methods.
    method invocationId {hub} {
        set iid [incr InvocationId]
        dict set Invocations $iid $hub
        return $iid
    }

    ## Connects the client to the server URL.
    #
    # This involves the negotiation of socket conf parameters with a Handshake object
    method start {} {
        if {$Hubs == {}} {
            throw SIGNALR "No hubs registered in connection! Use addHub to add one."
        }
        if {$Handshake == {}} {
            set Handshake [::signalr::Handshake new $Url [lindex $Hubs 0]]
        }
        set Socket [::websocket::open [$Handshake connectUrl] [list [self] handleSocket]]
        my WaitForBeingStarted 5000 true
    }

    ## Disconnects the client from the server.
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

    ## Sends a message to the server.
    #
    # Should not be called directly. Configured hubs use it to send invocations.
    method send {message} {
        ::websocket::send $Socket text $message
    }

    ## Websocket callback.
    #
    # Parses and processes incoming messages.
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

    ## Called when a connection is established.
    method SetConnected {isConnected} {
        set Connected $isConnected
    }

    ## Wait for the start message to arrive
    #
    # Returns the started state, if successful. If throw is true, an error is thrown when
    # the timeout is reached.
    method WaitForBeingStarted {timeout throw} {
        # wait until we are actually started, but no longer than 5s
        after 5000 [list apply {{varName} {
            if {![set $varName]} {
                set $varName timeout
            }
        }} [self namespace]::Started]
        vwait [self namespace]::Started
        if {$Started eq "timeout"} {
            my stop
            if {$throw} {
                throw SIGNALR "Did not receive initialize message from server in time ($timeout ms)"
            }
            return timeout
        }
        set Started
    }
    
    ## Called when the initialize message is received.
    #
    # The client accepts connections not until the initialize message was received.
    method SetStarted {isStarted} {
        set Started $isStarted
    }

    ## General message parsing and processing.
    #
    # Called from [ParseAndProcessMessage] with normalized json string messages.
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

    ## Processes result messages for previous invocations.
    #
    # Calls the corresponding methods on the hub which issued the invocation.
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

    ## Processes control fields in the message.
    #
    # These are merely all fields except the M (method call) field
    method ProcessControlFields {msg} {
        set result {disconnect no reconnect no}
        if {[dict exists $msg D] && [dict get $msg D]} {
            # disconnect event received from server
            return [list disconnect yes]
        }
        if {[dict exists $msg T] && [dict get $msg T]} {
            # reconnect event from server
            dict set result reconnect yes
        }
        if {[dict exists $msg G]} {
            # The groups token is used for reconnection if necessary
            $Handshake setGroupsToken [dict get $msg G]
        }

        if {[dict exist $msg S] && [dict get $msg S]} {
            # start message received
            my SetStarted yes
        }

        return $result
    }

    ## Processes the M field of a message.
    #
    # This field contains method invocations on a hub or progress information
    # for a previous invocation.
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

## Private class to manage handshakes and socket configuration.
#
# An object of this class is used in the client to call the "management" REST endpoints of the
# signalr server, especially for the negotiation of socket configuration. After negotiation, the
# respective properties are filled and a websocket connection URL can be retrieved from this
# object, which is used to establish the stateful websocket connection.
# The parameters GroupsToken and MessageId are set from the connection in the flow of incoming
# messages when they are received. They are used for a reconnect to retrieve the state of the
# server which might have changed in between. If the server implements it, messages can be 
# retrieved which have not been delivered because of connection failure, etc. At least
# theoretically.
::ooh::class create ::signalr::Handshake {

    ## The protocol version. This is a constant.
    property PROTOCOL_VERSION 1.5

    ## Server URL
    property Url {}

    ## The connection data, is essentially a json array of the server hub(s) to connect to.
    property ConnectionData {} -get

    ## If special headers should be used for the websocket connection, they can be stored here.
    property Headers {} -get

    ## Socket Conf property, set from negotiation
    property ConnectionToken {} -get
    ## Socket Conf property, set from negotiation
    property ConnectionId {} -get
    ## Socket Conf property, set from negotiation
    property KeepAliveTimeout {} -get
    ## Socket Conf property, set from negotiation
    property DisconnectTimeout {} -get
    ## Socket Conf property, set from negotiation
    property ConnectionTimeout {} -get
    ## Socket Conf property, set from negotiation
    property TryWebSockets {} -get
    ## Socket Conf property, set from negotiation
    property ProtocolVersion {} -get
    ## Socket Conf property, set from negotiation
    property TransportConnectTimeout {} -get
    ## Socket Conf property, set from negotiation
    property LongPollDelay {} -get

    ## Set from the client when received and used as query parameter for reconnect
    property GroupsToken {} -get -set
    ## Set from the client when received and used as query parameter for reconnect
    property MessageId {} -get -set

    construct {url hub} {
        set Url [my NormalizeUrl $url]
        set ConnectionData [my GetConnectionData $hub]
        my Negotiate
    }

    ## Returns the websocket connect URL.
    #
    # This is either the initial connect URL (without groups token and message id) or
    # the reconnect URL (with groups token and message id, if available)
    method connectUrl {} {
        regexp {^(https?)://} $Url m scheme
        set wsUrl [if {[string match *s $scheme]} {
            regsub ^$scheme $Url wss
        } else {
            regsub ^$scheme $Url ws
        }]

        append wsUrl / connect ? [my SocketUrlQuery]
    }

    ## Formats the query string for the socket url above
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

    ## Calls the negotiate endpoint to retrieve websocket config parameters.
    method Negotiate {} {
        append url $Url / negotiate
        append url ? [http::formatQuery connectionData $ConnectionData clientProtocol 1.5]
        set socketConf [my CallManagementUrl $url]
        foreach {key val} [dict filter $socketConf script {k v} {expr {![string match Url $k]}}] {
            set $key [dict get $socketConf $key]
        }
    }

    ## Actual REST call procedure.
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

    ## Formats the connection data for negotiation.
    method GetConnectionData {hub} {
        json template {[{"name": "~S:hub"}]} [list hub $hub]
    }

    ## URL normalization helper.
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
