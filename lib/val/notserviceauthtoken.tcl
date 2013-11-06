## -*- tcl -*-
# # ## ### ##### ######## ############# #####################
## Stackato - Validation Type - Service Auth Tokens, Not
## Dependency: config @client

# # ## ### ##### ######## ############# #####################
## Requisites

package require Tcl 8.5
package require struct::list
package require lambda
package require cmdr::validate ;# Fail utility command.
package require stackato::mgr::client;# pulls v2 also
package require stackato::validate::common

debug level  validate/notserviceauthtoken
debug prefix validate/notserviceauthtoken {[debug caller] | }

# # ## ### ##### ######## ############# #####################
## Definition

namespace eval ::stackato::validate {
    namespace export notserviceauthtoken
    namespace ensemble create
}

namespace eval ::stackato::validate::notserviceauthtoken {
    namespace export default validate complete release
    namespace ensemble create

    namespace import ::cmdr::validate::common::fail
    namespace import ::cmdr::validate::common::complete-enum
    namespace import ::stackato::validate::common::refresh-client
    namespace import ::stackato::mgr::cspace
    namespace import ::stackato::v2
}

proc ::stackato::validate::notserviceauthtoken::default  {p}   { return {} }
proc ::stackato::validate::notserviceauthtoken::release  {p x} { return }
proc ::stackato::validate::notserviceauthtoken::complete {p x} { return {} }

proc ::stackato::validate::notserviceauthtoken::validate {p x} {
    debug.validate/notserviceauthtoken {}

    refresh-client $p

    set matches [struct::list filter [v2 service_auth_token list 1] [lambda {x o} {
	string equal $x	[$o @label]
    } $x]]

    if {![llength $matches]} {
	debug.validate/notserviceauthtoken {OK/canon = $x}
	return $x
    }
    debug.validate/notserviceauthtoken {FAIL}
    fail $p NOTSERVICEAUTHTOKEN "an unused service auth token label" $x
}

# # ## ### ##### ######## ############# #####################
## Ready
package provide stackato::validate::notserviceauthtoken 0
