## bittrex.tcl (created by Tloona here)

lappend auto_path .. ../..

package require signalr::client
package require zlib

## Hub implementation for a bittrex websocket API.
#
# See https://bittrex.github.io/api/v3#topic-Websocket-Overview
#
# We hook up the ticker method to receive a feed of coin tickers.
::ooh::class create ::bittrex-hub {
    extends ::signalr::hub

    ## subscribe to arbitrary channels.
    #
    # See the WebSocket API docs at bittrex for details.
    method subscribe {args} {
        my invoke Subscribe [json new array [concat array [lmap v $args {list string $v} ]]]
    }

    ## unsubscribe from arbitrary channels.
    #
    # See the WebSocket API docs at bittrex for details.
    method unsubscribe {args} {
        my invoke Unsubscribe [json new array [concat array [lmap v $args {list string $v} ]]]
    }

    ## override result
    method result {invocationId result} {
        set result [lindex $result 0]
        if {![dict get $result Success]} {
            puts "Error for invocation $invocationId : [dict get $result ErrorCode]"
        }
    }
    
    ## Example for a client invocation method
    #
    # This method is called from the signalr client when the "ticker" method is invoked
    # from the server in a message.
    method ticker {payload} {
        puts [my Unzip $payload]
    }

    ## inflates a base64 coded binary message
    #
    # bittrex choosed to zip and base64 code the message arguments before sending them.
    # This method reverts that.
    method Unzip {payload} {
        zlib inflate [binary decode base64 $payload]
    }
}

namespace import signalr::*

# create the bittrex hub. It must be named "c3".
bittrex-hub create c3 -name c3

# create the signalr client with bittrex hub plugged in
client create bittrex-ws -url https://socket-v3.bittrex.com/signalr -hubs c3

# start the client
bittrex-ws start

# subscribe to the ticker feed of BTC-USD. It will call the hubs [ticker] method
c3 subscribe ticker_BTC-USD

# after 10s its enough
after 10000 {
    c3 unsubscribe ticker_BTC-USD
    bittrex-ws stop
    set forever now
}

vwait forever
