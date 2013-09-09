# -*- tcl -*-
# # ## ### ##### ######## ############# #####################

## Copyright (c) 2011-2013 ActiveState Software Inc.
## See file doc/license.txt for the license terms.

# # ## ### ##### ######## ############# #####################
## Requisites

package require Tcl 8.5
package require url
package require fileutil
package require stackato::color
package require stackato::log
package require stackato::mgr::client
package require stackato::mgr::ctarget
package require stackato::mgr::self
package require stackato::term
package require stackato::validate::memspec
package require stackato::validate::stackname
package require stackato::yaml
package require varsub ; # Utility package, local, variable extraction and resolution
package require cmdr 0.4

namespace eval ::stackato::mgr {
    namespace export manifest
}
namespace eval ::stackato::mgr::manifest {
    namespace export {[0-9a-z]*}
    namespace ensemble create

    namespace import ::stackato::color
    namespace import ::stackato::log::display
    namespace import ::stackato::log::err
    namespace import ::stackato::log::say!
    namespace import ::stackato::mgr::client
    namespace import ::stackato::mgr::ctarget
    namespace import ::stackato::mgr::self
    namespace import ::stackato::term
    namespace import ::stackato::validate::memspec
    namespace import ::stackato::validate::stackname
    namespace import ::stackato::v2
    namespace import ::stackato::yaml

    # More direct access to the yaml constructor commands.
    namespace import ::stackato::yaml::cmap ; rename cmap Cmapping
    namespace import ::stackato::yaml::cseq ; rename cseq Csequence
    namespace import ::stackato::yaml::cval ; rename cval Cscalar

    # Notes on module state / data structures (See also 'manifest::reset').

    # theconfig:      A cmdr::config instance. Through this we can reach
    #                 all parameters. Saved during setup.
    #
    # basepath:       Toplevel directory for the application sources.
    #                 Usually the CWD, overridable via --path (config @path).
    #
    # rootfile:       Path of the main manifest file.
    #                 Usually searched for relative to basepath and up.
    #                 Overridable via --manifest (config @manifest).
    #
    # manifest:       In-memory representation of the manifest information.
    #                 Partially tagged YAML data.
    #                 For additional structural notes see "ValidateStructure".
    #                 This structure has file inheritance resolved, outmanifest
    #                 information merged, and all symbols resolved.
    #
    # currentapp:     Reference (name) to the currently active application.
    # currentreq:     Flag if the application must be found in the manifest.
    #
    # currentappinfo: In memory data of the application definition.
    #                 A slice of 'manifest' (applications:<currentapp>)
    #                 Initialized lazily (--> current=, and InitCurrent).
    # currentdef:     Flag indicating that currentappinfo is initialized.
    #
    # outmanifest:    Data for a manifest to generate and save (on push).
    #
    # docache:        A list of application names.
    #                 Cache for the result of "DependencyOrdered".

    variable stdignore {
	.git/
	*.svn/
	.hg/
	*CVS/
	_FOSSIL_ .fos .fslckout
	*.bzr
	*.cdv
	*.pc
	*RCS
	*SCCS
	*_MTN
	*_build
	*_darcs
	*_sgbak
	*autom4te.cache
	*blib
	*cover_db
	*~
	\#*\#
	*.log
	*~.dep
	*~.dot
	*~.nib
	*~.plst
	~*/
    }
}

debug level  mgr/manifest/core
debug prefix mgr/manifest/core {[debug caller] | }
# NOTE: TODO: FUTURE: Use levels to control detail
debug level  mgr/manifest/core/resolve
debug prefix mgr/manifest/core/resolve {[debug caller] | }

# # ## ### ##### ######## ############# #####################
## Initialize the manifest manager. Once.

proc ::stackato::mgr::manifest::config= {p _} {
    debug.mgr/manifest/core {}
    variable theconfig [$p config]
    return
}

proc ::stackato::mgr::manifest::Init {} {
    variable theconfig
    $theconfig @manifest/setup
    return
}

# Retrieve the value of the hidden state variable. This
# initializes it, and calls "setup-from-config" here, as a
# 'when-defined' callback. Any access after the first returns a
# cached value, not running the initalization again.
#
# Variants:
#    $config   @manifest/setup
#    $p config @manifest/setup

# Must be executed by all public manifest acesssors.
# The out-manifest commands however do not require it.
# The main exceptions are "reset" and "setup*", and,
# of course, all the internal commands.

# Additionally the commands checking for a defined application name
# (on_user, user_all, user_1app) defer setup until the manifest is
# actually needed, i.e. to on_all_1plus, and on_single)

# # ## ### ##### ######## ############# #####################
## API. Our own. Hide structural details of the manifest from higher levels.
## Write to a manifest.
##
## NOTE: The generated structure is that of stackato.yml, with only CF
##       specific parts (like url, and extended framework) in manifest.yml
##       syntax. This also assumes a single-application manifest.

proc ::stackato::mgr::manifest::save {dstfile} {
    variable outmanifest

    debug.mgr/manifest/core {=== Saving to $dstfile}
    debug.mgr/manifest/core {=== RECORDED MANIFEST FROM INTERACTION ====}
    debug.mgr/manifest/core {[yaml dump-retag $outmanifest]}
    debug.mgr/manifest/core {===========================================}

    tclyaml writeTags file $dstfile [yaml retag-mapping-keys $outmanifest]

    debug.mgr/manifest/core {Saved}
    return
}

proc ::stackato::mgr::manifest::resetout {} {
    debug.mgr/manifest/core {}
    variable          outmanifest
    unset -nocomplain outmanifest
    return
}

proc ::stackato::mgr::manifest::name= {name} {
    debug.mgr/manifest/core {}
    variable outmanifest
    InitializeOutManifest
    yaml dict set outmanifest name [Cscalar $name]
    return
}

proc ::stackato::mgr::manifest::url= {urls} {
    debug.mgr/manifest/core {}
    variable outmanifest
    InitializeOutManifest

    # NOTE: We are generating a CF v1 manifest.yml structure here.
    # IOW "applications" is a mapping keyed by application "path"
    # (Here ".").

    set path [yaml dict get' $outmanifest app-dir .]

    if {[llength $urls] > 1} {
	set ts {}
	foreach u $urls {
	    lappend ts [Cscalar $u]
	}
	yaml dict set outmanifest applications $path url \
	    [Csequence {*}$ts]
    } else {
	yaml dict set outmanifest applications $path url \
	    [Cscalar [lindex $urls 0]]
    }
    return
}

proc ::stackato::mgr::manifest::instances= {n} {
    debug.mgr/manifest/core {}
    variable outmanifest
    InitializeOutManifest
    yaml dict set outmanifest instances [Cscalar $n]
    return
}

proc ::stackato::mgr::manifest::path= {path} {
    debug.mgr/manifest/core {}
    variable outmanifest
    InitializeOutManifest
    yaml dict set outmanifest app-dir [Cscalar $path]
    return
}

proc ::stackato::mgr::manifest::mem= {mem} {
    debug.mgr/manifest/core {}
    variable outmanifest
    InitializeOutManifest
    yaml dict set outmanifest memory [Cscalar $mem]
    return
}

proc ::stackato::mgr::manifest::disk= {disk} {
    debug.mgr/manifest/core {}
    variable outmanifest
    InitializeOutManifest
    yaml dict set outmanifest disk [Cscalar $disk]
    return
}

proc ::stackato::mgr::manifest::framework= {type} {
    debug.mgr/manifest/core {}
    variable outmanifest
    InitializeOutManifest
    yaml dict set outmanifest framework type [Cscalar $type]
    return
}

proc ::stackato::mgr::manifest::runtime= {runtime} {
    debug.mgr/manifest/core {}
    variable outmanifest
    InitializeOutManifest
    yaml dict set outmanifest framework runtime [Cscalar $runtime]
    return
}

proc ::stackato::mgr::manifest::command= {command} {
    debug.mgr/manifest/core {}
    variable outmanifest
    InitializeOutManifest
    yaml dict set outmanifest command [Cscalar $command]
    return
}

proc ::stackato::mgr::manifest::buildpack= {url} {
    debug.mgr/manifest/core {}

    # Ignore null.
    if {$url eq {}} return

    variable outmanifest
    InitializeOutManifest
    yaml dict set outmanifest buildpack [Cscalar $url]
    return
}

proc ::stackato::mgr::manifest::stack= {name} {
    debug.mgr/manifest/core {}
    # Ignore null.
    if {$name eq {}} return

    variable outmanifest
    InitializeOutManifest
    yaml dict set outmanifest stack [Cscalar $name]
    return
}

proc ::stackato::mgr::manifest::env= {env} {
    debug.mgr/manifest/core {}

    # env = dict (name -> value)
    if {![dict size $env]} return

    variable outmanifest
    InitializeOutManifest

    set tmp {}
    dict for {k v} $env {
	# Save in order servicename -> vendor
	lappend tmp $k [Cscalar $v]
    }

    yaml dict set outmanifest env [Cmapping {*}$tmp]
    return
}

proc ::stackato::mgr::manifest::services= {services} {
    debug.mgr/manifest/core {}

    # services = dict (servicename -> details)
    # details are a dict, appropriate to service/target
    if {![dict size $services]} return

    variable outmanifest
    InitializeOutManifest

    set tmp {}
    foreach {name details} $services {
	# Save in order servicename -> vendor
	lappend tmp $name [Cmapping {*}$details]
    }

    yaml dict set outmanifest services [Cmapping {*}$tmp]
    return
}

proc ::stackato::mgr::manifest::InitializeOutManifest {} {
    debug.mgr/manifest/core {}
    variable outmanifest
    if {[info exists outmanifest]} return
    set outmanifest {mapping {}}
    return
}

# # ## ### ##### ######## ############# #####################
## API. Our own. Hide structural details of the manifest from higher levels.
## Read from the manifest.

proc ::stackato::mgr::manifest::minVersionClient {v} {
    debug.mgr/manifest/core {}
    InitCurrent

    upvar 1 $v version
    variable currentappinfo
    if {![info exists currentappinfo]} { return 0 }
    return [yaml dict find $currentappinfo version \
		stackato min_version client]
}

proc ::stackato::mgr::manifest::minVersionServer {v} {
    debug.mgr/manifest/core {}
    InitCurrent

    upvar 1 $v version
    variable currentappinfo
    if {![info exists currentappinfo]} { return 0 }
    return [yaml dict find $currentappinfo version \
		stackato min_version server]
}

proc ::stackato::mgr::manifest::name {} {
    debug.mgr/manifest/core {}
    InitCurrent

    variable currentappinfo
    if {![info exists currentappinfo]} { return {} }
    return [yaml dict get' $currentappinfo name {}]
}

proc ::stackato::mgr::manifest::services {} {
    debug.mgr/manifest/core {}
    InitCurrent

    variable currentappinfo
    if {![info exists currentappinfo]} { return {} }
    return [yaml dict get' $currentappinfo services {}]
}

proc ::stackato::mgr::manifest::instances {} {
    debug.mgr/manifest/core {}
    InitCurrent

    variable currentappinfo
    if {![info exists currentappinfo]} { return 1 }
    return [yaml dict get' $currentappinfo instances 1]
}

proc ::stackato::mgr::manifest::runtime {} {
    debug.mgr/manifest/core {}
    InitCurrent

    variable currentappinfo
    if {![info exists currentappinfo]} { return {} }
    set res [yaml dict get' $currentappinfo runtime {}]
    debug.mgr/manifest/core {manifest::runtime ($currentappinfo)}
    debug.mgr/manifest/core {manifest::runtime ==> ($res)}
    return $res
}

proc ::stackato::mgr::manifest::command {} {
    debug.mgr/manifest/core {}
    InitCurrent

    variable currentappinfo
    if {![info exists currentappinfo]} { return {} }
    return [yaml dict get' $currentappinfo command {}]
}

proc ::stackato::mgr::manifest::buildpack {} {
    debug.mgr/manifest/core {}
    InitCurrent

    variable currentappinfo
    if {![info exists currentappinfo]} { return {} }
    return [yaml dict get' $currentappinfo buildpack {}]
}

proc ::stackato::mgr::manifest::stack {} {
    debug.mgr/manifest/core {}
    InitCurrent

    variable currentappinfo
    if {![info exists currentappinfo]} { return {} }
    set stack [yaml dict get' $currentappinfo stack {}]
    if {$stack ne {}} {
	set stack [stackname validate $stack]
    }
    return $stack
}

proc ::stackato::mgr::manifest::framework {} {
    debug.mgr/manifest/core {}
    InitCurrent

    variable currentappinfo
    if {![info exists currentappinfo]} { return {} }
    return [yaml dict get' $currentappinfo framework name {}]
}

proc ::stackato::mgr::manifest::framework-info {} {
    debug.mgr/manifest/core {}
    InitCurrent

    variable currentappinfo
    if {![info exists currentappinfo]} { return {} }
    return [yaml dict get' $currentappinfo framework info {}]
}

proc ::stackato::mgr::manifest::mem {} {
    debug.mgr/manifest/core {}
    variable theconfig
    InitCurrent

    variable currentappinfo
    if {![info exists currentappinfo]} { return {} }
    set mem [yaml dict get' $currentappinfo memory {}]
    if {$mem ne {}} {
	set mem [memspec validate [$theconfig @mem self] $mem]
    }
    return $mem
}

proc ::stackato::mgr::manifest::disk {} {
    debug.mgr/manifest/core {}
    variable theconfig
    InitCurrent

    variable currentappinfo
    if {![info exists currentappinfo]} { return {} }
    set disk [yaml dict get' $currentappinfo disk {}]
    if {$disk ne {}} {
	set disk [memspec validate [$theconfig @disk self] $disk]
    }
    return $disk
}

proc ::stackato::mgr::manifest::exec {} {
    debug.mgr/manifest/core {}
    InitCurrent

    variable currentappinfo
    if {![info exists currentappinfo]} { return {} }
    return [yaml dict get' $currentappinfo exec {}]
}

proc ::stackato::mgr::manifest::urls {} {
    debug.mgr/manifest/core {}
    InitCurrent

    variable currentappinfo
    if {[info exists currentappinfo] &&
	([yaml dict find-tagged $currentappinfo ulist url] ||
	 [yaml dict find-tagged $currentappinfo ulist urls])} {
	debug.mgr/manifest/core {Found = $ulist}

	yaml tags!do $ulist {key "url(s)"} tag data {
	    scalar   { return [list $data] }		
	    sequence { return [yaml strip-tags $ulist] }
	}
    } else {
	debug.mgr/manifest/core {Nothing}
	return {}
    }
}

proc ::stackato::mgr::manifest::p-web {} {
    debug.mgr/manifest/core {}
    InitCurrent

    variable currentappinfo
    if {[info exists currentappinfo] &&
	[yaml dict find $currentappinfo result \
	     stackato processes web]} {
	# Check for explicit null value, translate to empty.
	# (for the purposes of 'generic').
	if {$result in {null Null NULL ~}} { return {} }
	return $result
    } else {
	# undefined, empty for the purposes of 'generic'.
	return {}
    }
}

proc ::stackato::mgr::manifest::path {} {
    debug.mgr/manifest/core {}
    InitCurrent

    variable currentappinfo
    if {[info exists currentappinfo] &&
	[yaml dict find $currentappinfo result \
	    path]} {
	return $result
    } else {
	variable basepath
	return $basepath
    }
}

proc ::stackato::mgr::manifest::standalone {} {
    debug.mgr/manifest/core {}
    InitCurrent

    variable currentappinfo
    # A defined processes/web key which is empty, or null means 'standalone'.
    # An undefined key is _not_ standalone, but default serverside handling.
    if {[info exists currentappinfo] &&
	[yaml dict find $currentappinfo result \
	     stackato processes web] &&
	($result in {{} null Null NULL ~})} {
	return 1
    } else {
	# undefined, or not empty. NOT standalone.
	return 0
    }
}

proc ::stackato::mgr::manifest::env {} {
    debug.mgr/manifest/core {}
    InitCurrent

    variable currentappinfo
    if {![info exists currentappinfo]} { return {} }
    return [yaml dict get' $currentappinfo stackato env {}]
}

proc ::stackato::mgr::manifest::ignorePatterns {} {
    debug.mgr/manifest/core {}
    InitCurrent

    variable stdignore
    variable currentappinfo

    # The defaults contain patterns to drop the dot-files and
    # -directories of various source code control systems.

    if {![info exists currentappinfo]} { return $stdignore }
    return [yaml dict get' $currentappinfo stackato ignores $stdignore]
}

# # ## ### ##### ######## ############# #####################
## API (vmc - mgr/manifest_helper.rb)

proc ::stackato::mgr::manifest::have {} {
    debug.mgr/manifest/core {}
    Init

    variable manifest
    info exists manifest
}

proc ::stackato::mgr::manifest::count {} {
    debug.mgr/manifest/core {}
    Init

    llength [select_apps 0]
}

proc ::stackato::mgr::manifest::user_all {mode config cmd {revers 0}} {
    # user choices(s) or all in manifest.
    # each app is handled separately by 'cmd'.

    debug.mgr/manifest/core {}

    if {[on_user $mode $config $cmd]} {
	debug.mgr/manifest/core {/done}
	return
    }

    on_all_1plus $mode $config $cmd $revers

    debug.mgr/manifest/core {/done}
    return
}

proc ::stackato::mgr::manifest::user_1app_do {avar script} {
    debug.mgr/manifest/core {}

    variable theconfig
    upvar 1 $avar theapp

    # Inlined forms of on_user and on_single.
    # Slightly stripped (no modes, hardwired 'each').

    if {[$theconfig @application set?]} {
	set theapp [$theconfig @application]
	uplevel 1 $script
    } else {
	$theconfig @application set [get_single]

	set theapp [$theconfig @application]
	uplevel 1 $script

	$theconfig @application reset
    }
    return
}

proc ::stackato::mgr::manifest::user_1app {mode config cmd} {
    # user choices(s) or single in manifest.
    # each app is handled separately by 'cmd'.

    debug.mgr/manifest/core {}

    if {[on_user $mode $config $cmd]} {
	debug.mgr/manifest/core {/done}
	return
    }

    return [on_single $cmd]
}

proc ::stackato::mgr::manifest::on_user {mode config cmd} {
    # user choices(s)
    # each app is handled separately by 'cmd'.

    # mode in {merge, *, each, |}

    # Dependency: config @application, single|list
    debug.mgr/manifest/core {}

    if {![$config @application set?]} {
	debug.mgr/manifest/core {/done, nothing}
	return 0
    }

    set client [$config @client]

    # Dynamically change behaviour depending on @application parameter
    # list-ness, and mode.

    if {[$config @application list]} {
	set applications [$config @application]

	if {$mode in {merge *}} {
	    debug.mgr/manifest/core {list and merge}

	    # NOTE! No version checks, no current application.
	    {*}$cmd $config {*}$applications

	    debug.mgr/manifest/core {/done, stop caller}
	    return 1
	}
    } else {
	set applications [list [$config @application]]
    }

    debug.mgr/manifest/core {single or each}

    # mode in {each |}

    foreach theapp $applications {
	# theapp may be a string (= app name) or an object (= v2/app
	# instance), dependening on various factors (validation type
	# of config @application, client v1/v2). introspect the result
	# to dynamically get the proper appname for the selection in
	# the manifest.

	if {[info object isa object $theapp]} {
	    set appname [$theapp @name]
	} else {
	    set appname $theapp
	}

	debug.mgr/manifest/core {user defined = ($appname)}

	current= $appname
	MinVersionChecks
	{*}$cmd $config $theapp
    }

    debug.mgr/manifest/core {/done, stop caller}
    return 1
}

proc ::stackato::mgr::manifest::on_all_1plus {mode config cmd {revers 0}} {
    # Dependency: config @application
    debug.mgr/manifest/core {}
    Init

    # Due to the checks in TransformASStackato and TransformCFManifest
    # all applications in the manifest, if any, are properly
    # named. There is no need to check here, or to ask the user.

    # We operate on all applications in the manifest, and expect to
    # find at least one.

    set oplist [select_apps 0]
    debug.mgr/manifest/core {manifest = ($oplist)}

    if {![llength $oplist]} {
	err "No application specified, and none found in the manifest."
    }

    if {$revers} {
	set oplist [lreverse $oplist]
    }

    # mode in {merge * each |}
    set client [$config @client]

    if {$mode in {merge *}} {
	debug.mgr/manifest/core {list and merge}

	if {![$config @application list]} {
	    $client internal "Expected @application list parameter"
	}

	# NOTE! No version checks, no current application.

	foreach name $oplist {
	    $config @application set $name
	}

	{*}$cmd $config {*}[$config @application]
	debug.mgr/manifest/core {/done}
	return
    }

    foreach_named_app name $oplist {
	MinVersionChecks
	# TODO: Possibly check this as separate phase, and report all
	# failures, not just first.

	# Pass the name into and through the command configuration.
	# This may validate the information (v2 targets, and
	# validation type of @application). If validated it may also
	# be transformed (object instance). The reason for pulling it
	# back from the config instead of passing the name directly
	# into the command prefix.

	# Note: Handle possible @application list-ness.

	if {[$config @application list]} {
	    $config @application reset
	    $config @application set $name
	    {*}$cmd $config [lindex [$config @application] 0]
	} else {
	    $config @application set $name
	    {*}$cmd $config [$config @application]
	}

	# The reset ensures that there is no leakage to other places.
    }

    debug.mgr/manifest/core {/done}
    return
}

proc ::stackato::mgr::manifest::on_all_0plus {mode config cmd {revers 0}} {
    # Dependency: config @application
    debug.mgr/manifest/core {}
    Init

    # Due to the checks in TransformASStackato and TransformCFManifest
    # all applications in the manifest, if any, are properly
    # named. There is no need to check here, or to ask the user.

    # We operate on all applications in the manifest, and expect to
    # find at least one.

    set oplist [select_apps 0]
    debug.mgr/manifest/core {manifest = ($oplist)}

    if {![llength $oplist]} {
	current= {}
	#MinVersionChecks
	#$config @application set $name
	{*}$cmd $config {}

	debug.mgr/manifest/core {/done, called for none}
	return
    }

    if {$revers} {
	set oplist [lreverse $oplist]
    }

    # mode in {merge * each |}
    set client [$config @client]

    if {$mode in {merge *}} {
	debug.mgr/manifest/core {list and merge}

	if {![$config @application list]} {
	    $client internal "Expected @application list parameter"
	}

	# NOTE! No version checks, no current application.

	foreach name $oplist {
	    $config @application set $name
	}

	{*}$cmd $config {*}[$config @application]
	debug.mgr/manifest/core {/done, merge}
	return
    }

    foreach_named_app name $oplist {
	MinVersionChecks
	# TODO: Possibly check this as separate phase, and report all
	# failures, not just first.

	# Pass the name into and through the command configuration.
	# This may validate the information (v2 targets, and
	# validation type of @application). If validated it may also
	# be transformed (object instance). The reason for pulling it
	# back from the config instead of passing the name directly
	# into the command prefix.

	# Note: Handle possible @application list-ness.

	if {[$config @application list]} {
	    $config @application reset
	    $config @application set $name
	    {*}$cmd $config [lindex [$config @application] 0]
	} else {
	    $config @application set $name
	    {*}$cmd $config [$config @application]
	}

	# The reset ensures that there is no leakage to other places.
    }

    debug.mgr/manifest/core {/done}
    return
}

proc ::stackato::mgr::manifest::on_single {cmd} {
    # Dependency: config @application
    debug.mgr/manifest/core {}
    variable theconfig
    Init

    set appname [get_single]
    debug.mgr/manifest/core {chosen = ($appname)}

    current= $appname
    MinVersionChecks

    # Pass the name into and through the command configuration.
    # This may validate the information (v2 targets, and
    # validation type of @application). If validated it may also
    # be transformed (object instance). The reason for pulling it
    # back from the config instead of passing the name directly
    # into the command prefix.

    # Note: @application list-ness is no issue.
    #       @application was not defined before,
    #       and this is the first and only 'set'.
    #
    # The reset ensures that there is no leakage to other places.

    $theconfig @application set $appname
    set result [{*}$cmd $theconfig [$theconfig @application]]
    $theconfig @application reset

    return $result
}

proc ::stackato::mgr::manifest::get_single {} {
    # Dependency: config @application
    debug.mgr/manifest/core {}

    # Due to the checks in TransformASStackato and TransformCFManifest
    # all applications in the manifest, if any, are properly
    # named. There is no need to check here, or to ask the user.

    variable theconfig
    set oplist [select_apps 0]
    debug.mgr/manifest/core {manifest = ($oplist)}

    if {[llength $oplist] > 1} {
	err " Found more than one application in the manifest.\n\tUnable to choose.\n\tPlease specify the application to operate on."
    }

    # One application found, or none.

    if {![llength $oplist]} {
	# No application in the manifest.
	# Ask the user for a name, if allowed.
	# If not use the directory name as app name.

	variable theconfig
	set oplist [list [askname]]
    }

    # One application (possibly interactively or heuristically chosen).

    set appname [lindex $oplist 0]
    debug.mgr/manifest/core {chosen = ($appname)}

    return $appname
}

proc ::stackato::mgr::manifest::askname {} {
    debug.mgr/manifest/core {}
    Init

    variable basepath
    set maybe [file tail $basepath]
    if {[cmdr interactive?]} {
	set proceed [term ask/yn \
	 "Would you like to use '$maybe' as application name ? "]
	if {$proceed} {
	    set appname $maybe
	    debug.mgr/manifest/core { name/usr/default = $appname}
	} else {
	    set appname [term ask/string "Application Name: "]
	    debug.mgr/manifest/core { name/usr/entry   = $appname}
	}
    } else {
	set appname $maybe
	debug.mgr/manifest/core { name/default     = $appname}
    }

    return $appname
}

proc ::stackato::mgr::manifest::current {} {
    debug.mgr/manifest/core {}
    Init

    variable currentapp
    return  $currentapp
}

proc ::stackato::mgr::manifest::currentInfo {dstfile version} {
    debug.mgr/manifest/core {}
    Init

    variable currentappinfo
    variable manifest
    variable basepath

    debug.mgr/manifest/core {currentInfo => $dstfile (version $version)}
    debug.mgr/manifest/core {=== APP INFO MANIFEST =====================}
    debug.mgr/manifest/core {[yaml dump-retag $currentappinfo]}
    debug.mgr/manifest/core {===========================================}
    debug.mgr/manifest/core {=== FULL MANIFEST =========================}
    debug.mgr/manifest/core {[yaml dump-retag $manifest]}
    debug.mgr/manifest/core {===========================================}

    # Start with the data of the chosen application, and wrap a new
    # outer container around it. The form of the container is target
    # dependent (API version). 

    if {[info exists currentappinfo]} {
	set cai [yaml tag! mapping $currentappinfo {}]
	if {[package vcompare $version 2] >= 0} {
	    # v2: 'applications' is sequence. One element.
	    # Rewrite the 'path' key back to relative.

	    dict set cai path [Cscalar [DenormPath [yaml tag! scalar [dict get $cai path] {}]]]
	    set todump [dict create applications [Csequence [Cmapping {*}$cai]]]
	} else {
	    # v1: 'applications' is mapping keyed by path. Fixed "." in the
	    # upload. Drop the 'path' key. Information is in the mapping itself now.

	    dict unset cai path
	    set todump [dict create applications [Cmapping . [Cmapping {*}$cai]]]
	}
    } else {
	set cai    {}
	set todump {}
    }

    # Further, copy all toplevel keys found in the manifest which are
    # not part of the application data. These are unknown keys (to us)
    # we should transfer as-is, in case the server understands them.

    foreach {k v} [yaml tag! mapping $manifest {}] {
	if {$k eq "applications"} continue
	if {[dict exists $cai $k]} continue
	dict set todump $k $v
    }

    # Finalize the wrapping. This is always a mapping.
    set todump [Cmapping {*}$todump]

    debug.mgr/manifest/core {   dump = $todump}

    # Bug 92878: Generate an empty tagged structure if the manifest is empty overall.
    #if {$todump eq {}} { set todump {mapping {}} }

    set todump [yaml retag-mapping-keys $todump]

    debug.mgr/manifest/core {  dump' = $todump}

    tclyaml writeTags file $dstfile $todump

    debug.mgr/manifest/core {=== GENERATED MANIFEST ====================}
    debug.mgr/manifest/core {[yaml dump-tagged $todump]}
    debug.mgr/manifest/core {===========================================}
    return
}

proc ::stackato::mgr::manifest::foreach_app {nv body {panic 1}} {
    debug.mgr/manifest/core {}
    Init

    upvar 1 $nv loopvariable

    foreach name [select_apps $panic] {
	Call $name loopvariable $body
    }

    debug.mgr/manifest/core {/done}
    return
}

proc ::stackato::mgr::manifest::foreach_named_app {nv names body} {
    debug.mgr/manifest/core {}
    Init

    upvar 1 $nv loopvariable

    foreach name $names {
	Call $name loopvariable $body
    }

    debug.mgr/manifest/core {/done}
    return
}

proc ::stackato::mgr::manifest::select_apps {{panic 1}} {
    variable manifest

    debug.mgr/manifest/core {}
    Init

    # NOTE: We may not have a manifest (= no applications).
    #       And of course a manifest may exist, but still be (de)void
    #       of applications, nonsensical as it may be.

    if {![info exists manifest] ||
	![yaml dict find-tagged $manifest theapplications applications]
    } {
	debug.mgr/manifest/core {-- No applications (panic $panic)}
	if {$panic} {
	    err "No applications"
	}
	debug.mgr/manifest/core {/done}
	return {}
    }

    # We have a manifest, and it does contain applications. Due to the
    # checks in TransformASStackato and TransformCFManifest all these
    # applications are properly named.

    set applications [yaml tag! mapping $theapplications {key "applications"}]

    # Now we can select the applications to invoke the body of
    # 'foreach_app' for.

    # (1) Check if the manifest contains one or more applications
    # whose full path is a prefix to the current directory.  If yes,
    # it means that the user's CWD is in that application's directory,
    # or deeper, and that we must operate on only these applications.
    #
    # (2) Otherwise we operate on all applications found in the
    #     manifest.
    #
    # Order is based on dependencies, if any, regardless of which of
    # the items (1), (2) applies.

    # NOTE/TODO: Conversion from sequence to mapping, can remember
    # ordering as implied dependencies.

    # This is where the app sources are. Usually the current working
    # directory. Can be specified with --path.
    variable basepath
    set where [file normalize $basepath]

    debug.mgr/manifest/core {    where = $where}

    # Order across all.
    set appnames [DependencyOrdered $applications]

    # Check for sub-directory specific applications.

    debug.mgr/manifest/core {    apps /[llength $appnames]}

    set selection {}
    foreach name $appnames {
	set definition [yaml tag! mapping [dict get $applications $name] "key \"applications\""]
	set thepath    [yaml tag! scalar  [dict get $definition path]    "key \"applications -> $name\""]

	debug.mgr/manifest/core {    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%}
	debug.mgr/manifest/core {    checking $name}
	debug.mgr/manifest/core {           @ $thepath}
	debug.mgr/manifest/core {       where $where}
	debug.mgr/manifest/core {           : [fileutil::stripPath $thepath $where]}

	if {[fileutil::stripPath $thepath $where] ne $where} {
	    # The application's path as specified in the manifest is a prefix of the base path. In other words, this application lives ...
	    lappend selection $name
	}
    }

    debug.mgr/manifest/core {    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%}

    if {[llength $selection]} {
	debug.mgr/manifest/core {/done ==> ($selection)}
	return $selection
    }

    if {$where ne [NormPath {}]} {
	err "The path '$basepath' is not known to the manifest '$rootfile'."
    }

    debug.mgr/manifest/core {/done (all ==> ($appnames)) }
    return $appnames
}

proc ::stackato::mgr::manifest::current= {name {musthave 0}} {
    debug.mgr/manifest/core {}
    debug.mgr/manifest/core {current = "$name"}

    variable currentapp $name
    variable currentreq $musthave

    if {$musthave} {
	InitCurrent
    }
    return
}

proc ::stackato::mgr::manifest::InitCurrent {} {
    debug.mgr/manifest/core {}

    variable manifest
    variable currentapp
    variable currentreq
    variable currentappinfo
    variable currentdef

    # No current application, do nothing
    if {![info exists currentapp]} return

    # Already called, do nothing
    if {[info exists currentdef]} return
    set currentdef 1

    # We have a chosen application, and no data for it, initalize it.
    Init

    debug.mgr/manifest/core {        | manifest  ? [info exists manifest]}
    debug.mgr/manifest/core {        | app $currentapp ? [expr {[info exists manifest] && [yaml dict find-tagged $manifest definition applications $currentapp]}]}

    if {![info exists manifest] ||
	![yaml dict find-tagged $manifest definition applications $currentapp]
    } {
	debug.mgr/manifest/core {        | no manifest data}
	if {$currentreq} {
	    err "Failed to find '$currentapp' in manifest."
	}
	return
    }

    debug.mgr/manifest/core {        | $definition}
    set currentappinfo $definition
    return
}

proc ::stackato::mgr::manifest::Call {name loopvar body} {
    debug.mgr/manifest/core {}

    variable currentapp     
    variable currentreq     
    variable currentappinfo 
    variable currentdef

    # Helper command for foreach_app.
    # Set current application and invoke the body.

    upvar 1 $loopvar loopvariable

    current=         $name

    debug.mgr/manifest/core {RUN}

    try {
	# Two levels up, caller of 'foreach_app'.
	set loopvariable $name
	uplevel 2 $body
    } finally {
	# A recursive call through foreach_app from the
	# body may have removed these already.
	catch { unset currentapp     }
	catch { unset currentreq     }
	catch { unset currentappinfo }
	catch { unset currentdef     }
    }

    debug.mgr/manifest/core {/DONE}
    return
}

# # ## ### ##### ######## ############# #####################
## API (vmc - cli/commands/base.rb, manifest parts)

proc ::stackato::mgr::manifest::reset {} {
    debug.mgr/manifest/core {}
    # Full reset of all state after a command has completed.
    variable basepath       ; unset -nocomplain basepath
    variable rootfile       ; unset -nocomplain rootfile
    variable manifest       ; unset -nocomplain manifest
    variable currentapp     ; unset -nocomplain currentapp
    variable currentreq     ; unset -nocomplain currentreq
    variable currentappinfo ; unset -nocomplain	currentappinfo
    variable outmanifest    ; unset -nocomplain outmanifest
    variable docache        ; unset -nocomplain docache
    variable bequiet        ; unset -nocomplain bequiet
    variable theconfig      ; unset -nocomplain theconfig
    return
}

proc ::stackato::mgr::manifest::quiet {args} {
    # Used as 'when-set' callback. The parameter and value arguments
    # are irrelevant and ignored.
    debug.mgr/manifest/core {}
    variable bequiet 1
    return
}

proc ::stackato::mgr::manifest::setup-from-config {p x} {
    debug.mgr/manifest/core {}
    setup \
	[$p config @path] \
	[$p config @manifest]
    return
}

proc ::stackato::mgr::manifest::setup {path manifestfile {reset {}}} {
    debug.mgr/manifest/core {manifest setup ($path) ($manifestfile) /$reset}

    variable basepath $path

    if {$reset ne {}} {
	variable rootfile ; unset -nocomplain rootfile
	variable manifest ; unset -nocomplain manifest
    }

    if {$manifestfile ne {}} {
	variable rootfile [file normalize $manifestfile]
    }

    FindIt
    ReportItsLocation
    ProcessIt
    return
}

# # ## ### ##### ######## ############# #####################
## Read structure and resolve symbols.

proc ::stackato::mgr::manifest::ProcessIt {} {
    debug.mgr/manifest/core {}
    variable rootfile
    variable manifest

    if {![info exists rootfile] ||
	($rootfile eq {})} {
	debug.mgr/manifest/core {No rootfile}
	return
    }

    debug.mgr/manifest/core {Rootfile = ($rootfile)}

    set manifest [LoadFileInherit $rootfile]

    # We now have the entire manifest in memory, with all inheritance
    # from other files resolved and merged. Time to perform the global
    # normalizations:
    # - Rewrite "path" information to use absolute paths.
    # - Rewrite any "depends-on-path" keys which were created back into
    #   "depends-on" (i.e. go from reference by path to reference by name).

    set manifest [TransformGlobal $manifest]

    debug.mgr/manifest/core {=== CANONICAL STRUCTURE ===================}
    debug.mgr/manifest/core {[yaml dump-retag $manifest]}
    debug.mgr/manifest/core {===========================================}

    ValidateStructure $manifest

    ResolveSymbols
    return
}

# # ## ### ##### ######## ############# #####################
## Read an inheritance tree of {stackato,manifest}.yml files

proc ::stackato::mgr::manifest::LoadFileInherit {rootfile {already {}}} {
    set rootfile [file normalize $rootfile]
    debug.mgr/manifest/core {}

    if {[dict exists $already $rootfile]} {
	Error "Circular manifest inheritance detected involving:\n\t[join [dict keys $already] \n\t]" \
	    INHERITANCE CYCLE
    }
    dict set already $rootfile .

    # Read and process the chosen manifest file. The resulting data
    # structure is normalized to the internal representation.

    set m [LoadFile $rootfile]

    # Merge data from the manifest files explicitly named as sources
    # to inherit from, if any.

    set manifest [yaml tag! mapping $m manifest]
    if {[dict exists $manifest inherit]} {
	debug.mgr/manifest/core {=== PROCESSING FILE INHERITANCE ===========}

	set inheritvalue [dict get $manifest inherit]
	# Keep the inheritance information out of the in-memory
	# representation, not relevant now that it resolved.
	dict unset manifest inherit
	set m [Cmapping {*}$manifest]

	yaml tags!do $inheritvalue {key "inherit"} itag inherit {
	    scalar {
		set ifile [NormPath $inherit $rootfile]
		# Resolves inheritance in the loaded file first.
		set m [yaml deep-merge $m [LoadFileInherit $ifile $already]]
	    }
	    sequence {
		foreach v $inherit {
		    set ifile [NormPath [yaml tag! scalar $v {inheritance element}] $rootfile]
		    # Resolves inheritance in the loaded file first.
		    set m [yaml deep-merge $m [LoadFileInherit $ifile $already]]
		}
	    }
	}

	debug.mgr/manifest/core {}
	debug.mgr/manifest/core {=== AFTER FILE INHERITANCE ================}
	debug.mgr/manifest/core {[yaml dump-retag $m]}
	debug.mgr/manifest/core {===========================================}
    }

    debug.mgr/manifest/core {}
    debug.mgr/manifest/core {=== LOADED ================================}
    debug.mgr/manifest/core {[yaml dump-retag $m]}
    debug.mgr/manifest/core {===========================================}

    return $m
}

# # ## ### ##### ######## ############# #####################
## Read a single {stackato,manifest}.yml file

proc ::stackato::mgr::manifest::LoadFile {path} {
    debug.mgr/manifest/core {}

    # Load a yml configuration file, either stackato.yml, or
    # manifest.yml. The transformation we apply (Decompose, etc.)
    # then unifies the structures, regardless of origin.

    if {[catch {
	# Note that we retrieve a __tagged__ data structure here.
	# This is needed to properly handle the deep merging and symbol
	# resolution, which requires type information. It also helps
	# to distinguish between variant values for some keys and their
	# canonicalization.

	set data [lindex [tclyaml readTags file $path] 0 0]
    } msg]} {
	err "Syntax error in \[$path\]: $msg"
    }

    if {![llength $data]} {
	set data {mapping {}}
    }

    debug.mgr/manifest/core {=== RAW TCL ===============================}
    debug.mgr/manifest/core {$data}
    debug.mgr/manifest/core {===========================================}

    debug.mgr/manifest/core {=== RAW ===================================}
    debug.mgr/manifest/core {[yaml dump-tagged $data]}
    debug.mgr/manifest/core {===========================================}

    # Make the result a bit easier to handle, by stripping the keys of
    # mappings of their tags, generating something more dict like.

    set data [yaml strip-mapping-key-tags $data]

    # Convert the incoming information to the internal representation.

    set data [Normalize $data]

    # Bug 93955. If we have user data from a "push" then merge this
    # in. The only place where this can happen so far is in the
    # methods 'AppName' and 'Push' (both lib/cmd/app.tcl).
    
    # 'AppName' reloads the manifest after the application name is
    # fully known, if it differs from the manifest. The merge below
    # then overwrites the file's name information with the user's
    # choice.

    # 'Push' does this after all the interaction, just before packing
    # and uploading the application's files. At that point we have all
    # the user's choices and have to merge them back into the system,
    # so that the generated manifest.yml properly incorporates them.

    # NOTE that the outmanifest uses stackato structure and thus must
    # be transformed to match the unified layout.

    variable outmanifest
    if {[info exists outmanifest]} {
	debug.mgr/manifest/core {=== OUTPUT MANIFEST}

	set out [TransformASStackato $outmanifest]

	debug.mgr/manifest/core {=== OUTPUT MANIFEST, MERGE ====}
	debug.mgr/manifest/core {[yaml dump-retag $out]}
	debug.mgr/manifest/core {===========================================}

	set data [yaml deep-merge $out $data]

	debug.mgr/manifest/core {=== CANONICAL STRUCTURE + USER CHOICES ====}
	debug.mgr/manifest/core {[yaml dump-retag $data]}
	debug.mgr/manifest/core {===========================================}
    }

    return $data
}

proc ::stackato::mgr::manifest::NormPath {path {root {}}} {
    debug.mgr/manifest/core {}
    variable rootfile
    if {$root eq {}} { set root $rootfile }
    return [file normalize [file join [file dirname $root] $path]]
}

proc ::stackato::mgr::manifest::DenormPath {path {root {}}} {
    debug.mgr/manifest/core {}
    variable rootfile
    if {$root eq {}} { set root $rootfile }
    set base [file dirname $root]
    return [fileutil::stripPath $base $path]
}

# # ## ### ##### ######## ############# #####################
## Symbol resolution helper commands.
## Resolve symbols in a fully loaded manifest structure.

proc ::stackato::mgr::manifest::ResolveSymbols {} {
    debug.mgr/manifest/core {}

    variable manifest

    # Start with the entire manifest as search context for symbol
    # definitions.
    set context [list $manifest]

    # Resolve the symbols found in application definitions first.

    if {[dict exists $manifest applications]} {
	yaml tags!do [dict get $manifest applications] {key "applications"} _ avalue {
	    mapping {
		set new {}
		foreach {key appdef} $avalue {
		    ResolveValue appdef $context
		    lappend new $key $appdef
		}
		dict set manifest applications $new
	    }
	}
    }

    ResolveValue manifest $context

    debug.mgr/manifest/core {}
    debug.mgr/manifest/core {=== AFTER SYMBOL RESOLUTION ===============}
    debug.mgr/manifest/core {[yaml dump-retag $manifest]}
    debug.mgr/manifest/core {===========================================}
    return
}

# Outside user: cmd/app.tcl
proc ::stackato::mgr::manifest::resolve {valuevar} {
    debug.mgr/manifest/core {}
    Init

    upvar 1 $valuevar value

    variable manifest
    variable outmanifest

    # Bug 93209. Changes made by the user (cmdline, interactive,
    # etc.), and stored in the manifest-to-be-saved have priority
    # over the data in the regular manifest.
    set contextlist {}
    if {[info exists outmanifest]} { lappend contextlist $outmanifest }
    if {[info exists manifest]}    { lappend contextlist $manifest    }

    ResolveValue value $contextlist

    debug.mgr/manifest/core {/done}
    return
}

proc ::stackato::mgr::manifest::ResolveValue {valuevar contextlist {already {}}} {
    debug.mgr/manifest/core/resolve {     ResolveValue ($valuevar)}
    debug.mgr/manifest/core/resolve {          Already ($already)}
    debug.mgr/manifest/core/resolve {          Context ($contextlist)}

    upvar 1 $valuevar value

    # NOTE: Consider a parameter to pipe in data about the key of the
    # value, for a better error message when encountering a bad type.
    yaml tags!do $value value thetag thevalue {
	mapping {
	    set new {}
	    foreach {key child} $thevalue {
		# Resolve variables in the key string as well.
		set newkey [ResolveSymbolsOfValue $key $contextlist $already]

		ResolveValue child [linsert $contextlist 0 $value] $already
		lappend new $newkey $child
	    }
	}
	sequence {
	    set new {}
	    foreach child $thevalue {
		ResolveValue child $contextlist $already
		lappend new $child
	    }
	}
	scalar {
	    set new [ResolveSymbolsOfValue $thevalue $contextlist $already]
	}
    }

    debug.mgr/manifest/core/resolve {   value' = ($new)}

    # Construct the resolved value.
    set value [list $thetag $new]
    return
}

proc ::stackato::mgr::manifest::ResolveSymbolsOfValue {value contextlist already} {
    debug.mgr/manifest/core/resolve {}

    return [varsub::resolve $value \
		[list ::stackato::mgr::manifest::ResolveSymbol $contextlist $already]]
}

proc ::stackato::mgr::manifest::ResolveSymbol {contextlist already symbol} {
    debug.mgr/manifest/core/resolve {ResolveSymbol ($symbol)}
    debug.mgr/manifest/core/resolve {      Already ($already)}
    debug.mgr/manifest/core/resolve {      Context ($contextlist)}

    # NOTE ! We test for and prevent infinite recursion on symbols
    # NOTE ! referencing themselves, directly or indirectly.

    if {[dict exists $already $symbol]} {
	Error "Circular symbol definition detected involving:\n\t[join [dict keys $already] \n\t]" \
	    SYMBOL CYCLE    
    }
    dict set already $symbol .

    switch -exact -- $symbol {
	target-base {
	    return [TargetBase $contextlist]
	}
	target-url {
	    return [TargetUrl $contextlist]
	}
	random-word {
	    return [format %04x [expr {int(0x100000 * rand())}]]
	}
	default {
	    if {![FindSymbol $symbol $contextlist symvalue]} {
		Error "Unknown symbol in manifest: $symbol" \
		    SYMBOL UNKNOWN
	    }
	    # Note: symvalue is plain string here, not tagged.

	    # Recursively resolve any symbols in the current symbol's
	    # value, converting into and out of tagged format.

	    set symvalue [Cscalar $symvalue]
            ResolveValue symvalue $contextlist $already
	    return [lindex $symvalue 1]
	}
    }
    error "Reached unreachable"
}

proc ::stackato::mgr::manifest::TargetUrl {{contextlist {}}} {
    debug.mgr/manifest/core/resolve {}

    if {[FindSymbol "target" $contextlist symvalue]} {
	# NOTE how this is NOT resolved recursively.
	debug.mgr/manifest/core {=> $symvalue}
	return $symvalue
    }

    set symvalue [ctarget get]
    # Chop a port specification off before use

    regsub {:\d+$} $symvalue {} symvalue

    debug.mgr/manifest/core         {domain = $symvalue}
    debug.mgr/manifest/core/resolve {config => $symvalue}
    return $symvalue
}

proc ::stackato::mgr::manifest::TargetBase {{contextlist {}}} {
    debug.mgr/manifest/core/resolve {}

    if {[FindSymbol "target" $contextlist symvalue]} {
	# NOTE how this is NOT resolved recursively.
	# vmc: config.base_of (strip first host element (until first .)

	set symvalue [url base $symvalue]

	debug.mgr/manifest/core/resolve {manifest => $symvalue}
	return  $symvalue
    }

    set symvalue [url base [TargetUrl]]

    debug.mgr/manifest/core/resolve {config => $symvalue}
    return $symvalue
}

proc ::stackato::mgr::manifest::FindSymbol {symbol contextlist resultvar} {
    upvar 1 $resultvar result

    foreach context $contextlist {
	if {![ResolveInContext $symbol $context result]} continue
	return 1
    }
    return 0
}

proc ::stackato::mgr::manifest::ResolveInContext {symbol context resultvar} {
    variable currentapp
    upvar 1 $resultvar result
    set app {}
    if {[info exists currentapp]} { set app $currentapp }

    set found [expr {
		  [yaml dict find-tagged $context localresult properties $symbol] ||
		  [yaml dict find-tagged $context localresult applications $app $symbol] ||
		  [yaml dict find-tagged $context localresult $symbol]
	      }]

    # Accept only scalar values for use in the
    # resolution. Interpolation of structured values is fraught with
    # peril and not supported. Of course this matters only if
    # we actually found a definition at all.

    if {!$found || ([yaml tag-of $localresult] ne "scalar")} {
	return 0
    }

    set result [yaml strip-tags $localresult]
    return 1
}

# # ## ### ##### ######## ############# #####################
## Locate the yaml files, our's and CF's.

proc ::stackato::mgr::manifest::FindIt {} {
    debug.mgr/manifest/core {}

    variable basepath
    variable rootfile

    if {[info exists rootfile]} {
	debug.mgr/manifest/core {manifest file = ($rootfile) /cached}
	return $rootfile
    }
    if {(![FindStackato.yml $basepath rootfile]) &&
	(![FindManifest.yml $basepath rootfile])} {
	set rootfile {}

	debug.mgr/manifest/core {manifest file - nothing found}
	return $rootfile
    }

    debug.mgr/manifest/core {manifest file = ($rootfile)}

    if {[file isdirectory $rootfile]} {
	err "Bad manifest \"$rootfile\", expected a file, got a directory"
    }
    return $rootfile
}

proc ::stackato::mgr::manifest::FindStackato.yml {path filevar} {
    upvar 1 $filevar ymlfile
    debug.mgr/manifest/core {find-stackato.yml ($path -> $filevar)}

    set setup $path/stackato.yml

    if {![file exists $setup]} {
	return 0
    }

    set ymlfile $setup
    return 1
}

proc ::stackato::mgr::manifest::FindManifest.yml {path filevar} {
    upvar 1 $filevar ymlfile
    debug.mgr/manifest/core {find-manifest.yml ($path -> $filevar)}
    #debug.mgr/manifest/core {}

    set path [file normalize $path]
    #set last $path

    while {1} {
	set setup $path/manifest.yml
	if {[file exists $setup]} {
	    set ymlfile $setup
	    return 1
	}

	set new [file dirname $path]

	# Stop on reaching the root of the path.
	if {$new eq $path} break
	set path $new
    }

    return 0
}

proc ::stackato::mgr::manifest::ReportItsLocation {} {
    debug.mgr/manifest/core {}
    variable rootfile
    variable showwarnings
    variable bequiet
    variable theconfig

    # Suppress reporting of the used manifest file when we are a
    # log-stream child process. This also disables all warnings about
    # manifest contents we may print otherwise.

    set showwarnings 0

    if {[$theconfig has @no-timestamps] &&
	[$theconfig @no-timestamps]} return

    # No reporting for specific commands which may be in trouble otherwise.
    # (currently only: ssh, scp, and run).

    if {[info exists bequiet] && $bequiet} return

    # Now that we have confirmed to not be in a reset, and being a
    # master process we activate printing of manifest warnings, and
    # report the manifest file currently used.

    set showwarnings 1

    if {$rootfile eq {}} {
	display "No manifest"
    } else {
	display "Using manifest file \"[fileutil::relative [pwd] $rootfile]\""
    }

    # Output is once only, disable any further.
    quiet
    return
}

# # ## ### ##### ######## ############# #####################
## Helper for LoadFile. Normalize the nformation, i.e. transform the
## external to the internal representation. Part of that is to separate
## stackato information, and transform to match the CF format, with
## extensions. Another part is to detect all syntax variants and
## convert them to a canonical form.

proc ::stackato::mgr::manifest::Normalize {data} {
    debug.mgr/manifest/core {}

    # Decompose the incoming structure into stackato and (cf) manifest
    # pieces, then transform the parts to match structures and merge
    # them back into one. This part unifies/canonicalizes the input,
    # regardless of the origin.

    # 1. Splitting.
    lassign [Decompose $data] stackato manifest

    debug.mgr/manifest/core {=== DEC STACKATO STRUCTURE ================}
    debug.mgr/manifest/core {[yaml dump-retag $stackato]}
    debug.mgr/manifest/core {===========================================}

    debug.mgr/manifest/core {=== DEC MANIFEST STRUCTURE ================}
    debug.mgr/manifest/core {[yaml dump-retag $manifest]}
    debug.mgr/manifest/core {===========================================}

    # 2. Transform AS Stackato piece
    if {[llength [lindex $stackato 1]]} {
	set stackato [TransformASStackato $stackato]

	debug.mgr/manifest/core {=== TRANS STACKATO STRUCTURE ==============}
	debug.mgr/manifest/core {[yaml dump-retag $stackato]}
	debug.mgr/manifest/core {===========================================}
    }

    # 3. Transform CF Manifest piece.
    if {[llength [lindex $manifest 1]]} {
	# Bug 97113.
	set manifest [TransformCFManifest $manifest]

	debug.mgr/manifest/core {=== TRANS CF/MANIFEST STRUCTURE ===========}
	debug.mgr/manifest/core {[yaml dump-retag $manifest]}
	debug.mgr/manifest/core {===========================================}
    }

    # 4. Merge together (unify)
    set data [yaml deep-merge $stackato $manifest]

    debug.mgr/manifest/core {=== MERGED STRUCTURE ======================}
    debug.mgr/manifest/core {[yaml dump-retag $data]}
    debug.mgr/manifest/core {===========================================}

    return $data
}

proc ::stackato::mgr::manifest::Decompose {yml} {
    debug.mgr/manifest/core {}

    # Assumes that the yml underwent StripMappingKeyTags
    # before provided as argument.

    # The code picks out which pieces are CF manifest.yml, and which
    # are stackato.yml, separating them into their own structures.

    set value [yaml tag! mapping $yml root]

    # Pull all the known stackato.yml keys (toplevel!) out of the
    # structure. The remainder is considered to be manifest.yml data.

    # Bug 98145. For the purposes of the transform the m.yml
    # _application_ keys "url", "urls", "inherit", and "depends-on"
    # are also recognized as s.yml _toplevel_ keys, and later moved
    # into the correct place.

    set s {}
    foreach k {
	name instances mem memory disk framework services processes
	min_version env ignores hooks cron requirements
	command app-dir url urls depends-on buildpack stack
    } {
	if {![dict exists $value $k]} continue
	set v [dict get $value $k]
	dict unset value $k
	lappend s $k $v
    }

    return [list [Cmapping {*}$s] [Cmapping {*}$value]]
}

proc ::stackato::mgr::manifest::TransformASStackato {yml} {
    debug.mgr/manifest/core {}

    # This code assumes that the input is the stackato.yml data for an
    # application and generates the canonical internal representation
    # for it.

    set value [yaml tag! mapping $yml root]

    if {![dict exists $value name]} {
	Error "The stackato application has no name" APP NAME MISSING
    }

    set name [yaml tag! scalar [dict get $value name] name]

    # CF v2 support/change. Canonical internal representation of
    # application definitions is mapping keyed by "name" (see end of
    # procedure). The stackato "app-dir" key is "path".

    # (1) If present rename "app-dir" to "path".
    #     If not present insert a default path (".").

    if {[dict exists $value app-dir]} {
	set appdir [yaml tag! scalar [dict get $value app-dir] {key "app-dir"}]
	dict unset value app-dir
    } else {
	set appdir .
    }
    dict set value path [Cscalar $appdir]

    # Transform all the known stackato.yml keys to match their
    # manifest.yml counterpart. Those without counterpart move into a
    # nested 'stackato' mapping.

    # name, instances, mem, disk - 1:1, nothing to change.
    # (4a) env: Has A/B variants, normalize

    # framework - handle stackato A/B variants and map.
    if {[dict exists $value framework]} {
	set value [TS_Framework $value]
    }

    # services - re-map (handle syntax variants re name/type vs key/value)
    if {[dict exists $value services]} {
	set value [TS_Services $value]
    }

    # Consolidate different spellings for mem|memory
    if {[dict exists $value mem]} {
	dict set value memory [dict get $value mem]
	dict unset value mem
    }

    # move into stackato sub-map
    # - requirements processes min_version env ignores hooks cron
    set value [TS_Isolate $value]

    # Normalize old/new style of env'ironment data.
    # This should be applied to the unified data, not just stackato.
    if {[dict exists $value stackato]} {
	set value [TransformStackato $value]
    }

    # Treat the stackato data as an application under the given name.
    return [Cmapping applications [Cmapping $name [Cmapping {*}$value]]]
}

proc ::stackato::mgr::manifest::TS_Framework {value} {
    # Note: scalar handling is identical to TCF_Framework,
    # but mapping is different ('type' 2 'name', move 'runtime' key).

    debug.mgr/manifest/core {}

    yaml tags!do [dict get $value framework] {key "framework"} tag f {
	scalar {
	    # stackato syntax A, f(ramework) = type = CF 'name'
	    dict set value framework [Cmapping name [Cscalar $f]]
	}
	mapping {
	    # stackato syntax B, f(ramework) = dict (type, runtime)

	    if {[dict exists $f type]} {
		set t [dict get $f type]
		# t is a tagged value
		dict set   f name $t
		dict unset f type
	    }
	    if {[dict exists $f runtime]} {
		set r [dict get $f runtime]
		# r is a tagged value
		dict set value runtime $r
		dict unset f runtime
	    }
	    # Done changing the framework content. Push the changes
	    # back into the outer dict.
	    if {![llength $f]} {
		dict unset value framework
	    } else {
		dict set value framework [list $tag $f]
	    }
	}
    }

    return $value
}

proc ::stackato::mgr::manifest::TS_Services {value} {
    debug.mgr/manifest/core {}

    yaml tags!do [dict get $value services] {key "services"} t services {
	scalar {
	    set services [string trim $services]
	    if {$services ne {}} {
		Error "Bad syntax, expected a yaml mapping for key \"services\", got a non-empty string instead." \
		    SYNTAX SERVICES
	    }
	}
	mapping {
	    # Data is fine. Nothing to do.
	}
    }

    set choices [TSS_Vendors]

    set new {}
    foreach {outer inner} $services {
	# 3 possibilities
	# (a) stackato.yml /old : (outer, inner) = (vendor, name/scalar)
	# (b) stackato.yml /new : (outer, inner) = (name, vendor/scalar)
	# (c) manifest.yml : (outer, inner) = (name, (mapping, 'type': vendor))

	yaml tags!do $inner {service definition} tag innervalue {
	    scalar {
		# (a, b)
		if {($outer in $choices) && ($innervalue ni $choices)} {
		    # (a)
		    set name   $innervalue
		    set vendor $outer

		    say! [color yellow "Deprecated syntax (vendor: name) in service specification \"$outer: $innervalue\".\n\tPlease swap, i.e. use (name: vendor)."]

		} elseif {($outer ni $choices) && ($innervalue in $choices)} {
		    # (b)
		    set name   $outer
		    set vendor $innervalue
		} elseif {($outer ni $choices) && ($innervalue ni $choices)} {
		    # Neither value is a proper vendor.
		    Error "Bad service definition \"$outer: $innervalue\" in manifest. Neither \[$outer\] nor \[$innervalue\] are supported system services.\nPlease use '[self me] services' to see the list of system services supported by the target." \
			BAD SERVICE
		} else {
		    # Both values are proper vendors.
		    Error "Bad service definition \"$outer: $innervalue\" in manifest. Both \[$outer\] and \[$innervalue\] are supported system services. Unable to decide which is the service name." \
			BAD SERVICE
		}
	    }
	    mapping {
		# (c)
		set name   $outer
		set type   [dict get $innervalue type]
		set vendor [yaml tag! scalar $type type]
	    }
	}

	lappend new $name [Cmapping type [Cscalar $vendor]]
    }
    dict set value services [Cmapping {*}$new]

    return $value
}

proc ::stackato::mgr::manifest::TSS_Vendors {} {
    debug.mgr/manifest/core {}

    set client [client authenticated]
    set choices {}

    if {[$client isv2]} {
	set choices [struct::list map [v2 service list] [lambda s {
	    $s @label
	}]]
    } else {
	foreach {service_type value} [$client services_info] {
	    foreach {vendor version} $value {
		lappend choices $vendor
	    }
	}
    }

    debug.mgr/manifest/core {/done ==> ($choices)}
    return $choices
}

proc ::stackato::mgr::manifest::TS_Isolate {value} {
    debug.mgr/manifest/core {}

    foreach k {
	processes min_version env ignores hooks cron
	requirements
    } {
	if {![dict exists $value $k]} continue

	set data [dict get $value $k]

	# Need the sub-map, create if not present yet.
	if {![dict exists $value stackato]} {
	    dict set value stackato {}
	}
	# Put into sub-map, untagged.
	dict set value stackato $k $data

	# Drop from original location
	dict unset value $k
    }

    if {[dict exists $value stackato]} {
	# Fix the tagging.
	dict set value stackato [Cmapping {*}[dict get $value stackato]]
    }

    return $value
}

proc ::stackato::mgr::manifest::TransformStackato {value} {
    debug.mgr/manifest/core {}

    yaml tags!do [dict get $value stackato] {key "stackato"} t data {
	mapping {
	    if {[dict exists $data env]} {
		set data [TransformEnvironment $data]
		dict set value stackato [Cmapping {*}$data]
	    }
	}
    }

    return $value
}

proc ::stackato::mgr::manifest::TransformEnvironment {data} {
    debug.mgr/manifest/core {}

    set old [dict get $data env]

    set new {}
    foreach {ekey evalue} [yaml tag! mapping $old {key "env"}] {
	yaml tags!do $evalue "value of key \"env:$ekey\"" etag _ {
	    scalar {
		# Old style. Scalar value. Transform into new
		# style, make the value the default.
		lappend new $ekey [Cmapping default $evalue]
	    }
	    mapping {
		# New-style, mapping. Passed through unchanged.
		lappend new $ekey $evalue
	    }
	}
    }

    dict set data env [Cmapping {*}$new]
    return $data
}


proc ::stackato::mgr::manifest::TransformCFManifest {yml} {
    debug.mgr/manifest/core {}

    # The input data is a structure of either a CF v1 or v2 manifest.
    # The main difference is in the type of the "applications" key
    # (mapping -> v1, sequence -> v2).
    #
    # We normalize both forms to a mapping. The difference is that the
    # v1 mappins is keyed by path, and the internal representation
    # will be keyed by name.

    set value [yaml tag! mapping $yml root]

    # (1) Separate toplevel keys (anything ni {applications, properties})
    set result       {}
    set applications {}
    set toplevel     {}

    yaml tags!do $yml root _ value {
	mapping {
	    foreach {k v} $value {
		switch -exact -- $k {
		    applications {
			# Remember for upcoming transforms.
			set applications $v
		    }
		    inherit -
		    properties   {
			# Passed into result, not needed here.
			lappend result $k $v
		    }
		    default {
			# Remember for upcoming transforms.
			dict set toplevel $k $v
		    }
		}
	    }
	}
    }

    # (2) Extend toplevels with a default "path" (".").
    if {![dict exists $toplevel path]} {
	dict set toplevel path [Cscalar .]
    }

    debug.mgr/manifest/core {apps = ($applications)}
    debug.mgr/manifest/core {top  = ($toplevel)}
    debug.mgr/manifest/core {res  = ($result)}

    if {[llength $applications]} {
	# (3) Transform a v2 sequence
	# or  Transform a v1 mapping (keyed by path)
	# Both times the result is a mapping keyed by name.

	yaml tags!do $applications {key "applications"} _ value {
	    mapping {
		debug.mgr/manifest/core {v1 - mapping/path to mapping/name}

		# v1 format. Data is a mapping keyed by "path".
		# Rewrite this into a mapping keyed by "name".

		# Also, look for the key "depends-on" in each
		# application definition, and rename them to
		# "depends-on-path". Their values are lists of
		# references to other applications by "path", and the
		# rename triggers the rewrite into lists of references
		# by name, at which point they will be renamed back to
		# "depends-on". See TG_FixDependencies for the place,
		# and its caller, TransformGlobal.
		#
		# We cannot do it here, as we do not have the full
		# list of applications and their names and paths.

		foreach {path appdef} $value {
		    # Pull name for keying.

		    set appdef [yaml tag! mapping $appdef applications:$path]

		    if {![dict exists $appdef name]} {
			Error "Application @ path \"$path\" has no name" APP NAME MISSING
		    }

		    set name [yaml tag! scalar [dict get $appdef name] name]

		    # Save path information.
		    dict set appdef path [Cscalar $path]

		    # Rewrite (rename) depends-on
		    if {[dict exists $appdef depends-on]} {
			dict set   appdef depends-on-path [dict get $appdef depends-on]
			dict unset appdef depends-on
		    }
		    lappend new $name [Cmapping {*}$appdef]
		}
	    }
	    sequence {
		debug.mgr/manifest/core {v2 - sequence to mapping/name}

		# v2 format. Data is a sequence of mappings, each with
		# application name and path (*). Rewrite this into a
		# mapping keyed by name.
		#
		# Here we leave "depends-on" applications keys alone,
		# as they are already lists of references by name.
		#
		# (Ad *) Those without path information will get it
		# when the toplevel keys are merged into their
		# definition, see below (4), and (2) above for the
		# default..

		set n 0
		foreach appdef $value {
		    set def [yaml tag! mapping $appdef applications:<$n>]

		    if {![dict exists $def name]} {
			Error "Application <$n> has no name" APP NAME MISSING
		    }

		    set name [yaml tag! scalar [dict get $def name] name]
		    lappend new $name $appdef
		    incr n
		}
	    }
	}
	set applications [Cmapping {*}$new]

	# (4) At this point the application data is a mapping keyed by
	# name, canonical. It is time to replicate the toplevel keys
	# collected at (1) into each definition, and handle some
	# per-application canonicalization (stackato:env).  Note that
	# the first implicitly ensures that all applications have path
	# information, via (2) above.

	yaml tags!do $applications {key "applications"} _ value {
	    mapping {
		debug.mgr/manifest/core {toplevel replicate}

		foreach {name appdef} $value {
		    set appdef [yaml deep-merge $appdef [Cmapping {*}$toplevel]]
		    set appdef [TransformCFManifestApp $name $appdef]

		    lappend new $name $appdef
		}
	    }
	}
	set applications [Cmapping {*}$new]

	lappend result applications $applications
    }

    # (5) Assemble and return...

    debug.mgr/manifest/core {res  = ($result)}

    return [Cmapping {*}$result]
}

proc ::stackato::mgr::manifest::TransformCFManifestApp {a yml} {
    debug.mgr/manifest/core {}

    # See caller (TransformCFManifest) for notes.
    # To transform: framework+runtime, if framework value is a scalar.

    set value [yaml tag! mapping $yml applications:$a]

    if {[dict exists $value framework]} {
	set value [TCF_Framework $value]
    }

    # Consolidate different spellings for mem|memory
    if {[dict exists $value mem]} {
	dict set value memory [dict get $value mem]
	dict unset value mem
    }

    # At this point 'framework is either missing, or exists as a mapping.

    # Bug 97958: Moving runtime to framework:runtime seems to be wrong. Disabled. Removed.

    # Normalize old/new style of env'ironment data.
    # This should be applied to the unified data, not just stackato.
    if {[dict exists $value stackato]} {
	set value [TransformStackato $value]
    }

    #array set __ $value ; parray __ ; unset __

    return [Cmapping {*}$value]
}

proc ::stackato::mgr::manifest::TCF_Framework {value} {
    # Note: scalar handling is identical to TS_Framework,
    # but mapping is different (nothing to do here).

    debug.mgr/manifest/core {}

    yaml tags!do [dict get $value framework] {key "framework"} tag f {
	scalar {
	    # CF framework is scalar. Transform to mapping, with value moved to sub-key name.

	    dict set value framework [Cmapping name [Cscalar $f]]
	}
	mapping {
	    # Nothing to do, mapping is right.
	}
    }

    return $value
}

proc ::stackato::mgr::manifest::TransformGlobal {yml} {
    debug.mgr/manifest/core {}

    yaml tags!do $yml root _ value {
	mapping {
	    # Read/Modify/Write of applications.
	    set apps [dict get $value applications]

	    # .../Modify
	    yaml tags!do $apps {key "applications"} _ apps {
		mapping {
		    # Rewrite "path" to absolute value, and remember a
		    # mapping "path to name".
		    set nameof {}
 		    foreach {name appdef} $apps {
			lappend new $name [TG_NormalizePath $name $appdef nameof]
		    }
		    set apps $new

		    debug.mgr/manifest/core {[unset _ ; array set _ $nameof ; parray _ ; unset _]}

		    # Look for and rewrite "depends-on-path" keys back
		    # to "depends-on" keys.  The former contains a
		    # list of references by path, the latter uses a
		    # list of references by name. The mapping from the
		    # loop above is used for this.

		    foreach {name appdef} $apps {
			lappend new $name [TG_FixDependencies $name $appdef $nameof]
		    }

		    set apps $new
		}
	    }

	    # .../Write back
	    dict set value applications [Cmapping {*}$apps]
	}
    }

    return [Cmapping {*}$value]
}

proc ::stackato::mgr::manifest::TG_NormalizePath {name appdef mapvar} {
    debug.mgr/manifest/core {}

    upvar 1 $mapvar nameof

    yaml tags!do $appdef "key \"applications -> $name\"" _ appdef {
	mapping {
	    set path  [yaml tag! scalar [dict get $appdef path] "applications -> $name:path"]
	    set npath [NormPath $path]

	    dict set nameof $npath $name
	    dict set appdef path [Cscalar $npath]

	    debug.mgr/manifest/core {($path) ==> F($npath)}
	    debug.mgr/manifest/core {($path) ==> N($name)}
	}
    }

    debug.mgr/manifest/core {/done}
    return [Cmapping {*}$appdef]
}

proc ::stackato::mgr::manifest::TG_FixDependencies {name appdef nameof} {
    debug.mgr/manifest/core {}

    if {![yaml dict exists $appdef depends-on-path]} {
	debug.mgr/manifest/core {/done, no change}
	return $appdef
    }

    # Has old-style dependencies in need of conversion. Unbox.

    yaml tags!do $appdef "key \"applications -> $name\"" _ appdef {
	mapping {
	    # Read references ...
	    set deps [dict get $appdef depends-on-path]

	    # ... modify them ...
	    yaml tags!do $deps "key \"applications -> $name:depends-on\"" tag deps {
		scalar {
		    set new [Cscalar [TGFD_NameOf [NormPath $deps]]]
		}
		sequence {
		    set new {}
		    foreach d $deps {
			yaml tags!do $d "key \"applications -> $name:depends-on element\"" _ ref {
			    scalar {
				lappend new [Cscalar [TGFD_NameOf [NormPath $ref]]]
			    }
			}
		    }
		    set new [Csequence {*}$new]
		}
	    }

	    # ... and write the result back
	    dict unset appdef depends-on-path
	    dict set   appdef depends-on $new
	}
    }

    debug.mgr/manifest/core {/done, rewritten}

    # Rebox
    return [Cmapping {*}$appdef]
}

proc ::stackato::mgr::manifest::TGFD_NameOf {path} {
    debug.mgr/manifest/core {}

    upvar 1 nameof nameof

    # First handle possibility of paths which have no associated
    # name. Bail out as error, see also <DependencyOrdered> for the
    # equivalent check on the names.

    if {![dict exists $nameof $path]} {
	Error "Reference (path) '$path' in key \"depends-on\" is unknown." \
	    APP-DEPENDENCY UNKNOWN
    }

    set name [dict get $nameof $path]

    debug.mgr/manifest/core {==> ($name)}
    return $name
}

# # ## ### ##### ######## ############# #####################

proc ::stackato::mgr::manifest::ValidateStructure {yml} {
    debug.mgr/manifest/core {}

    # Validate the structure of the yml as much as possible
    # (I.e. expect mappings, sequences, strings, etc. ...)

    # This is done by explicitly recursing into the tagged structure
    # of the yaml data and testing the tags encountered, based on the
    # keys seen.

    set applications [lindex [dict get' [yaml tag! mapping $yml root] applications {mapping {}}] 1]

    foreach {path appspec} $applications {
	yaml validate-glob $appspec application -- akey avalue {
	    name      -
	    instances -
	    memory    -
	    disk      -
	    runtime   -
	    path      -
	    buildpack -
	    stack     -
	    command   { yaml tag! scalar $avalue "key \"$akey\"" }
	    url        -
	    urls       -
	    depends-on {
		yaml tags! {scalar sequence} $avalue "key \"$akey\""
	    }
	    services  {
		yaml validate-glob $avalue services -- skey svalue {
		    * {
			yaml validate-glob $svalue $akey:$skey -- key value {
			    type { yaml tag! scalar $value {key "type"} }
			    * {
				upvar 1 key ekey
				UnknownKey $akey:$skey:$key
			    }
			}
		    }
		}
	    }
	    framework {
		yaml validate-glob $avalue framework -- key value {
		    name          { yaml tag!     scalar $value {key "framework:name"} }
		    runtime       { yaml tag!     scalar $value {key "framework:runtime"} }
		    app-server    { yaml tag!warn scalar $value {key "framework:app-server"} }
		    document-root { yaml tag!warn scalar $value {key "framework:document-root"} }
		    home-dir      { yaml tag!warn scalar $value {key "framework:home-dir"} }
		    start-file    { yaml tag!warn scalar $value {key "framework:start-file"} }
		    *             { UnknownKey framework:$key }
		}
	    }
	    stackato {
		yaml validate-glob $avalue stackato -- skey svalue {
		    min_version {
			yaml validate-glob $svalue min_version -- key value {
			    server {
				set v [yaml tag! scalar $value {key "min_version:server"}]
				if {[catch {
				    package vcompare 0 $v
				}]} {
				    Error "Expected version number for key \"min_version:server\", got \"$v\"" \
					TAG
				}
			    }
			    client {
				set v [yaml tag! scalar $value {key "min_version:client"}]
				if {[catch {
				    package vcompare 0 $v
				}]} {
				    Error "Expected version number for key \"min_version:client\", got \"$v\"" \
					TAG
				}
			    }
			    * { IllegalKey min_version:$key }
			}
		    }
		    processes {
			yaml validate-glob $svalue processes -- key value {
			    web { yaml tag! scalar $value {key "processes:web"} }
			    *   { UnknownKey processes:$key }
			}
		    }
		    requirements {
			yaml validate-glob $svalue requirements -- key value {
			    pypm   { yaml tags! {scalar sequence} $value {key "requirements:pypm"} }
			    ppm    { yaml tags! {scalar sequence} $value {key "requirements:ppm "} }
			    cpan   { yaml tags! {scalar sequence} $value {key "requirements:cpan"} }
			    pip    { yaml tags! {scalar sequence} $value {key "requirements:pip "} }
			    ubuntu { yaml tags! {scalar sequence} $value {key "requirements:ubuntu"} }
			    redhat { yaml tags! {scalar sequence} $value {key "requirements:redhat"} }
			    unix   { yaml tags! {scalar sequence} $value {key "requirements:unix  "} }
			    staging {
				yaml validate-glob $value staging -- key value {
				    ubuntu { yaml tags! {scalar sequence} $value {key "requirements:staging:ubuntu"} }
				    redhat { yaml tags! {scalar sequence} $value {key "requirements:staging:redhat"} }
				    unix   { yaml tags! {scalar sequence} $value {key "requirements:staging:unix  "} }
				    *      { UnknownKey requirements:staging:$key }
				}
			    }
			    running {
				yaml validate-glob $value running -- key value {
				    ubuntu { yaml tags! {scalar sequence} $value {key "requirements:running:ubuntu"} }
				    redhat { yaml tags! {scalar sequence} $value {key "requirements:running:redhat"} }
				    unix   { yaml tags! {scalar sequence} $value {key "requirements:running:unix  "} }
				    *      { UnknownKey requirements:running:$key }
				}
			    }
			    * { UnknownKey requirements:$key }
			}
		    }
		    env {
			yaml validate-glob $svalue env -- ekey evalue {
			    * {
				# We assume normalized data here! See
				# marker "4a" in TransformASStackato.
				yaml validate-glob $evalue "env:$ekey" -- key value {
				    default {
					yaml tag! scalar $value "key \"env:${ekey}:default\""
				    }
				    hidden -
				    required -
				    inherit {
					set value [yaml tag! scalar $value "key \"env:${ekey}:$key\""]
					if {$value ni {y Y yes Yes YES n N no No NO true True TRUE false False FALSE on On ON off Off OFF}} {
					    Error "Expected boolean value for key \"env:$ekey:$key\", got \"$value\"" \
						TAG
					}
				    }
				    prompt {
					yaml tag! scalar $value "key \"env:${ekey}:prompt\""
				    }
				    choices {
					yaml tag! sequence $value "key \"env:${ekey}:choices\""
				    }
				    scope {
					set value [yaml tag! scalar $value "env:${ekey}:scope"]
					if {$value ni {staging runtime both}} {
					    Error "Expected one of 'both', 'runtime' or 'staging' for key \"env:$ekey:scope\", got \"$value\"" \
						TAG
					}
				    }
				    * {
					IllegalKey env:${ekey}:$key
				    }
				}
			    }
			}
		    }
		    hooks {
			yaml validate-glob $svalue hooks -- ky value {
			    pre-staging  { ValidateCommand $value hooks:pre-staging  }
			    post-staging { ValidateCommand $value hooks:post-staging }
			    pre-running  { ValidateCommand $value hooks:pre-running  }
			    *            { UnknownKey hooks:$key }
			}
		    }
		    cron    { ValidateCommand $svalue cron }
		    ignores {
			yaml tag! sequence $svalue {key "ignores"}
		    }
		    * {
			UnknownKey stackato:$skey
		    }
		}
	    }
	    * {
		UnknownKey $akey
	    }
	}
    }

    foreach {k v} [yaml tag! mapping $yml root] {
	if {$k eq "applications"} continue
	if {$k eq "inherit"}      continue
	UnknownKey $k
    }
    return
}

proc ::stackato::mgr::manifest::IllegalKey {k} {
    Error "Found illegal key \"$k\"" TAG
}

proc ::stackato::mgr::manifest::Error {text args} {
    return \
	-code error \
	-errorcode [list STACKATO CLIENT CLI MANIFEST {*}$args] \
	"Manifest error: $text"
}

proc ::stackato::mgr::manifest::UnknownKey {k} {
    #error $k
    variable showwarnings
    if {!$showwarnings} return
    say! [color yellow "Manifest warning: Unknown key \"$k\""]
    return
}

proc ::stackato::mgr::manifest::ValidateCommand {value key} {
    yaml tags!do $value "key \"$key\"" tag value {
	scalar   {}
	sequence {
	    # all elements must be scalar.
	    foreach element $value {
		yaml tag! scalar $element "element of sequence key \"$key\""
	    }
	}
    }
    return
}

# # ## ### ##### ######## ############# #####################
## Helper. Order a set of applications by their dependencies

proc ::stackato::mgr::manifest::DependencyOrdered {dict} {
    debug.mgr/manifest/core {DependencyOrdered}

    variable docache
    if {[info exists docache]} { return $docache }

    # Note: Our topological sorter is an iterative solution, not
    # recursive as the original ruby, and doesn't make use of
    # yield/coro/uplevel either.

    array set required {} ; # app name -> count of dependencies
    array set users    {} ; # app name -> list of apps depending on this one.
    set remainder      {} ; # list of not yet processed apps.
    set result         {} ; # Outgoing list, properly ordered.

    # Fill the dependency structures.
    # Note: dict is keyed by application name.

    foreach {name config} $dict {
	debug.mgr/manifest/core {DependencyOrdered: $name = $config}

	lappend remainder $name
	set     required($name) 0

	if {[yaml dict find $config dependencies depends-on]} {
	    set required($name) [llength $dependencies]
	    foreach d $dependencies {
		lappend users($d) $name
	    }
	}
    }

    # Check that the dependencies do not mention applications which
    # are not specified by the manifest. See also <TGFD_NameOf> for
    # equivalent check on old-style path references (during their
    # conversion to name references).

    foreach a [array names users] {
	if {[info exists required($a)]} continue
	Error "Reference '$a' in key \"depends-on\" is unknown." \
	    APP-DEPENDENCY UNKNOWN
    }

    # Iteratively move the applications without dependencies into the
    # result, and adjust the dependency counters of their users, until
    # all applications are processed, or nothing could be moved. The
    # latter indicating one or more cycles.

    debug.mgr/manifest/core {DependencyOrdered: Returning}

    while {[llength $remainder]} {
	set keep {}

	foreach r $remainder {
	    if {$required($r) > 0} {
		# Elements still having dependencies are kept for the
		# next round.
		lappend keep $r
	    } else {
		# Elements without dependencies move to the result.
		# The dependency counts of their users get adjusted down.
		# This may allow their move to the result later on.
		# Possibly even in this round already.

		debug.mgr/manifest/core {DependencyOrdered: $r = [dict get $dict $r]}

		lappend result $r
		if {[info exists users($r)]} {
		    foreach u $users($r) {
			incr required($u) -1
		    }
		    unset users($r)
		}
		unset required($r)
	    }
	}

	if {[llength $keep] == [llength $remainder]} {
	    # Oops. Nothing was processed in this round.  This means
	    # that all the remaining elements are in at least one
	    # dependency cycle (could be several).
	    Error "Circular application dependency detected involving:\n\t[join $remainder \n\t]" \
		APP-DEPENDENCY CYCLE
	}

	# Prepare for the next round, if any.
	set remainder $keep
    }

    set docache $result
    return $result
}

# # ## ### ##### ######## ############# #####################

proc ::stackato::mgr::manifest::min-version-checks {} {
    MinVersionChecks
}

proc ::stackato::mgr::manifest::MinVersionChecks {} {
    variable theconfig

    # Check client and server version requirements, if there are
    # any. Note that that manifest(s) have been read and processed
    # already, by the base class constructor.

    # Note: The requirements come from the manifest, and have been
    # check for proper syntax already. The have's should be ok.

    if {[minVersionClient require]} {
	set have [package present stackato::cmdr]

	debug.mgr/manifest/core { client require = $require}
	debug.mgr/manifest/core { client have    = $have}

	if {[package vcompare $have $require] < 0} {
	    err "version conflict for client: have $have, need at least $require"
	}
    }
    if {[minVersionServer require]} {
	set have [client server-version [$theconfig @client]]

	debug.mgr/manifest/core { server require = $require}
	debug.mgr/manifest/core { server have    = $have}

	if {[package vcompare $have $require] < 0} {
	    err "version conflict for server: have $have, need at least $require"
	}
    }
    return
}

# # ## ### ##### ######## ############# #####################
## Ready
package provide stackato::mgr::manifest 0