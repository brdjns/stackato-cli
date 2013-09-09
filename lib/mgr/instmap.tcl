# -*- tcl -*-
# # ## ### ##### ######## ############# #####################

## Copyright (c) 2011-2013 ActiveState Software Inc.
## See file doc/license.txt for the license terms.

# # ## ### ##### ######## ############# #####################

## This module manages the map from instance names to numeric instance
## id's, as generated by the crashes command.

# # ## ### ##### ######## ############# #####################
## Requisites

package require Tcl 8.5
package require stackato::mgr::cfile
package require fileutil
package require json
package require stackato::jmap

namespace eval ::stackato::mgr {
    namespace export instmap
    namespace ensemble create
}

namespace eval ::stackato::mgr::instmap {
    namespace export set get reset save
    namespace ensemble create

    namespace import ::stackato::mgr::cfile
}

# # ## ### ##### ######## ############# #####################

debug level  mgr/instmap
debug prefix mgr/instmap {[debug caller] | }

# # ## ### ##### ######## ############# #####################
## API

proc ::stackato::mgr::instmap::set {name} {
    debug.mgr/instmap {}
    variable current $name
    return
}

proc ::stackato::mgr::instmap::get {} {
    debug.mgr/instmap {}
    variable current

    if {![info exists current]} {
	#checker -scope line exclude badOption
	::set current [Load]
    }
    return $current
}

proc ::stackato::mgr::instmap::reset {} {
    debug.mgr/instmap {}
    variable current {}
    return
}

proc ::stackato::mgr::instmap::save {} {
    debug.mgr/instmap {}
    variable current
    Store $current
    return
}

# # ## ### ##### ######## ############# #####################

proc ::stackato::mgr::instmap::Load {} {
    debug.mgr/instmap {}

    ::set path [cfile get instances]
    if {![fileutil::test $path efr]} {
	return {}
    }
    return [json::json2dict \
		[string trim \
		     [fileutil::cat $path]]]
}

proc ::stackato::mgr::instmap::Store {instances} {
    debug.mgr/instmap {}
    ::set path [cfile get instances]
    fileutil::writeFile   $path [stackato::jmap instancemap $instances]\n
    cfile fix-permissions $path
    return
}

# # ## ### ##### ######## ############# #####################
## Ready
package provide stackato::mgr::instmap 0