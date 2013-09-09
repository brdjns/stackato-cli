# -*- tcl -*-
# # ## ### ##### ######## ############# #####################

## Core v2 operations
## - Pagination for list/search/filter
## - Conversion from retrieved json to v2entity instances.
## - Utility commands

## - Knows target
## - Knows user (implicit, actually know auth token)
## - Knows group (stackato)
## - Knows organization/space
##   (CF2 concepts overlapping with Stackato groups).

# # ## ### ##### ######## ############# #####################

package require Tcl 8.5
package require try            ;# I want try/catch/finally
package require TclOO
package require base64
package require json 1.2       ;# requiring many-json2dict
package require stackato::jmap
package require stackato::form2

package require http
#puts [package ifneeded http [package present http]]
package require restclient

# # ## ### ##### ######## ############# #####################
## Pull in the entity support and other foundation code.

package require stackato::v2::app
package require stackato::v2::app_event
package require stackato::v2::domain
package require stackato::v2::organization
package require stackato::v2::quota_definition
package require stackato::v2::route
package require stackato::v2::service
package require stackato::v2::service_auth_token
package require stackato::v2::service_binding
package require stackato::v2::service_instance
package require stackato::v2::managed_service_instance
package require stackato::v2::service_plan
package require stackato::v2::space
package require stackato::v2::stack
package require stackato::v2::user

# # ## ### ##### ######## ############# #####################

debug level  v2/client
debug prefix v2/client {[debug caller] | }

namespace eval ::stackato {
    namespace export v2
    namespace ensemble create
}
namespace eval ::stackato::v2 {
    namespace export client
    namespace ensemble create
}
namespace eval ::stackato::v2::client {}

# # ## ### ##### ######## ############# #####################

oo::class create ::stackato::v2::client {
    superclass ::REST

    # # ## ### ##### ######## #############
    ## State

    variable mytarget myhost myuser myproxy myauth_token \
	mytrace myprogress myheaders \
	myclientinfo

    method target    {} { return $mytarget }
    method authtoken {} { return $myauth_token }
    method proxy     {} { return $myproxy }
    method user      {} { return $myuser }

    # # ## ### ##### ######## #############
    ## Life cycle

    constructor {target_url auth_token} {
	debug.v2/client {}
	debug.v2/client {[ploc autoproxy]}

	if {$target_url eq {}} {
	    my TargetError "No target defined"
	}

	#set myclientinfo {}
	set myhost {}
	set myuser {}
	set myproxy {}
	set mytrace 0
	set myprogress 0

	# Namespace import, sort of.
	namespace path [linsert [namespace path] end \
			    ::stackato ::stackato::log]

	set myauth_token $auth_token
	set mytarget     [url canon $target_url]

	set myheaders {}
	if {$myauth_token ne {}} {
	    lappend myheaders AUTHORIZATION $myauth_token

	    my decode_token [lindex $auth_token 1]
	}

	proc ::http::Log {args} {}
	proc ::http::Log {args} { return
	    set prefix "[::stackato::color cyan HTTP:] "
	    set text $prefix[join [split [join $args] \n] "\n$prefix"]
	    ::stackato::log say $text
	}

	# Initialize the integrated REST client. Late initialization
	# of the proxy-settings.

	if {
	    [string match https://* $mytarget] &&
	    [info exists ::env(https_proxy)]
	} {
	    set nop {}
	    catch { set nop $::env(no_proxy) }
	    autoproxy::init $::env(https_proxy) $nop
	} else {
	    autoproxy::init
	}

	next $mytarget \
	    -progress [callback Upload] \
	    -blocksize 1024 \
	    -headers $myheaders

	# NOTE: IN create_app's http_post the server does a redirect
	# we must not follow. It is unclear if other commands rely on
	# us following a redirection.  -follow-redirections 1
    }

    destructor {
	debug.v2/client {}
    }

    # # ## ### ##### ######## #############
    ## API

    # # ## ### ##### ######## #############
    ## Versioning. Same methods as the v1 client.
    ## Different answers however.

    method isv2 {} { return yes }

    method api-version {} {
	set v [dict get [my info] version]
	debug.v2/client {==> $v}
	return $v
    }

    method version {} {
	debug.v2/client { = [package present stackato::v2::client]}
	return [package present stackato::v2::client]
    }

    method group? {} {
	# No group for v2.
	return {}
    }

    # # ## ### ##### ######## #############
    ## Target information. Cached. New writer method
    ## required to avoid redundant /info query when switching from v1
    ## client over to v2.

    # Retrieves information on the target cloud, and optionally the
    # logged in user

    method info {} {
	debug.v2/client {}
	variable myclientinfo
	# TODO: Should merge for new version IMO, general, services, user_account

	if {[info exists myclientinfo]} { return $myclientinfo }
	set myclientinfo [my json_get /info] ; # TODO: New constants (v2)

	# Keys:
	#   Always:
	#   - allow_debug            : boolean
	#   - authorization_endpoint : url (in string)
	#   - build                  : string (value looks integer)
	#   - description            : string
	#   - name                   : string
	#   - support                : url (in string)
	#   - token_endpoint         : url (in string)
	#   - version                : integer

	#   When logged in, i.e. with proper authorization:
	#   - limits.*    : object
	#   - usage.*     : object
	#   - user        : &user (GUID)

	return $myclientinfo
    }

    method info= {dict} {
	debug.v2/client {}
	variable myclientinfo $dict
	return
    }

    method info_reset {} {
	debug.v2/client {}
	unset myclientinfo
	return
    }

    # # ## ### ##### ######## #############
    ## REST tracing

    method trace? {} {
	return [my cget -trace]
    }

    method trace {trace} {
	set mytrace $trace
	# Setup tracing if needed
	if {$mytrace ne {}} {
	    #dict set myheaders X-VCAP-Trace [expr {$mytrace == 1 ? 22 : $mytrace}]
	    my configure -trace 1
	} else {
	    #dict unset myheaders X-VCAP-Trace
	    my configure -trace 0
	}
	#my configure -headers $myheaders
	return
    }

    # # ## ### ##### ######## #############
    ## Login check based on /info data.

    method logged_in? {} {
	debug.v2/client {}
	set descr [my info]
	if {![llength $descr]} {
	    # No /info, not logged in.
	    debug.v2/client {No. No information}
	    return 0
	}

	# Check existence of relevant information (user, and usage).
	try {
	    if {![my HAS $descr user]}  {
		debug.v2/client {No. User field missing}
		return 0
	    }
	    # In v2 the 'usage' field can be missing even when logged in.
	    if {0&&![my HAS $descr usage]} {
		debug.v2/client {No. Usage field missing}
		return 0
	    }
	} on error {e o} {
	    my TargetError "Login check choked on bad server response, please check if the server is responsive."
	}

	# Cache user for later
	set myuser [dict get $descr user]
	debug.v2/client {Yes -> $myuser}
	return 1
    }

    # Check if the user is logged in, and admin
    method admin? {} {
	# The V2 UAA always requires a password for log in.
	# An admin cannot just supply a name to 'sudo' to
	# somebody else.
	return 0
    }

    ######################################################
    # Apps
    ######################################################

    method upload-by-url {url zipfile {resource_manifest {}}} {
	debug.v2/client {}
	#@type zipfile = path

	#FIXME, manifest should be allowed to be null, here for compatability with old cc's
	#resource_manifest ||= []
	#my check_login_status

	set resources [jmap resources $resource_manifest]

	set dst $url

	# v2 always uses a multipart/form-data payload to upload the
	# application bits, zip file or not. Without zip file the
	# relevant form field is simply not provided. Furthermore, the
	# form field "_method" has been dropped.

	form2 start   data
	form2 field   data resources $resources
	if {$zipfile ne {}} {
	    form2 zipfile data application $zipfile
	}
	lassign [form2 compose data] contenttype data dlength

	if {0} {
	    # Debugging ... Stream to temp file for review, and stream
	    # upload from the same file because the cat and subordinates
	    # are destroyed by the fcopy.
	    set c [open UPLOAD_FORM w]
	    fconfigure $c -translation binary
	    fcopy $data $c
	    close $data
	    close $c
	    set data [open UPLOAD_FORM r]
	    fconfigure $data -translation binary

	    set dlength [file size UPLOAD_FORM]
	}

	debug.v2/client {$contenttype | $dlength := $data}

	# Provide rest/http with the content-length information for
	# the non-seekable channel
	dict set myheaders content-length $dlength
	my configure -headers $myheaders

	set tries 10

	set myprogress 1
	while {$tries} {
	    incr tries -1
	    try {
		my http_put $dst $data $contenttype
	    } \
		trap {REST HTTP REFUSED} {e o} - \
		trap {REST HTTP BROKEN} {e o} {
		    if {!$tries} { return {*}$o $e }

		    say! \n[color red "$e"]
		    say "Retrying in a second... (trials left: $tries)"
		    after 1000
		    continue
		}
	    break
	}

	dict unset myheaders content-length
	my configure -headers $myheaders

	set myprogress 0
	return
    }

    method Upload {token total n} {
	if {!$myprogress} return
	# This code assumes that the last say* was the prefix
	# of the upload progress display.

	set p [expr {$n*100/$total}]
	again+ ${p}%

	if {$n >= $total} {
	    display " [color green OK]"
	    clearlast
	    #display ""
	}
	return
    }

    ######################################################
    # Resources
    ######################################################

    # Send in a resources manifest array to the system to have
    # it check what is needed to actually send. Returns array
    # indicating what is needed. This returned manifest should be
    # sent in with the upload if resources were removed.
    # E.g. [{:sha1 => xxx, :size => xxx, :fn => filename}]

    method check_resources {resources} {
	#@type resources = list (dict (size, sha1, fn| */string))

	# Operations coming before should have checked login status already.
	#my check_login_status

	set data [lindex \
		      [my http_put \
			   /v2/resource_match \
			   [jmap resources $resources] \
			   application/json] \
		      1]

	try {
	    set response [json::json2dict $data]
	} on error {e o} {
	    return -code error -errorcode {STACKATO SERVER DATA ERROR} \
		"Received invalid JSON from server; Error: $e"
	}

	return $response
    }

    # # ## ### ##### ######## #############

    method decode_token {token} {
	debug.v2/client {[ploc json]}
	debug.v2/client {[ploc base64]}

	variable mytdata
	# Decode the token and remember the hidden information.

	# Note: The token contains non-base64 characters in various
	# places.  Namely dot, dash, and underscore. These do not seem
	# to correlate to the token's underlying structure, except
	# that the first dot seems to indicate the end of the first
	# json. The others are apparently just sprinkled in.

	# Note 2: The server delivers sometimes essentially invalid
	# base64 data. Incorrect length, leading to implicit padding
	# ===. That is forbidden. The pure Tcl base64 branch in Tcllib
	# simply ignores such characters. Trf doesn't and fails.

	# Note 2a: The pure Tcl branch actually ignores all trailing
	# characters if there is no explicit padding with '='. That is
	# a bug in that code!

	# To work around the borken length I remove the irrelevant
	# characters, then check if there is a bad character by
	# length. If yes it gets chopped off before proceeding.
	#
	# The issues with the pure Tcl base64 branch tcllib are
	# ignored, as that doesn't get used, Trf is underneath.

	set token [string map {. {} - {} _ {}} $token]
	if {([string length $token] % 4) == 1} {
	    set token [string range $token 0 end-1]
	}

	# Now we can throw the data into the actual decoder.

	set text [base64::decode $token]
	debug.v2/client {hidden text ($text)}

	# The text contains 2 json objects, followed by binary data
	# (of varying length, seen 171|247, so far). The meaning of
	# the binary is currently not known.

	set parsed [json::many-json2dict $text 2]

	#debug.v2/client {parsed  ($parsed)}
	#foreach r $decoded {puts @@@@@; catch {unset _};::array set _ $r;parray _;catch {unset _}};puts @@@@@

	debug.v2/client {number of items = [llength $parsed]}
	foreach item $parsed {
	    debug.v2/client {item = ($item)}
	}
	# Show only the first two. The remainder is garbage out of the trailing binary.
	foreach item [lrange $parsed 0 1] {
	    debug.v2/client {formatted = [stackato jmap map dict $item]}
	}

        # Keys:
        # (1) alg        RS256  meaning unknown
        #
        # (2) aud        list of something
        #     cid        "cf"
        #     client_id  "cf"
        #     email      user email == user_name
        #     exp        token expiration, seconds since epoch
        #     grant_type password
        #     iat        token generation, seconds since epoch
        #     iss        token generation url
        #   * jti        ???
        #   * scope      list of permissions?
        #     sub        == user_id, othrewise unknown
        #   x user_id    uuid, type user
        #     user_name  name of the user, also see 'email'
        #
        # (Ad *) Seems to be the same as in the outer auth response.
        # (Ad x) Same as 'user' reported by /info

	set mytdata [lindex $parsed 1]
	return
    }

    method current_user {} {
	debug.v2/client {}
	# Expects decoded token data
	variable mytdata
	if {![info exists mytdata]} { return N/A }
	return [dict get' $mytdata email [dict get' $mytdata user_id N/A]]
    }

    # # ## ### ##### ######## #############
    ## Perform login by name and password

    method login {user password} {
	debug.v2/client {}

	# NOTE: This is an extreme shortcut through the morass of what
	# code I saw in the ruby client.

	# The ruby client has lots of additional classes, like
	# CFoundry:UAAClient, CF:UAA:TokenIssuer, AuthToken, etc. with
	# lots of functionality distributed across things, routed
	# through superclasses, aspects, delegated components,
	# auto-initalized on first use, etc. pp. ... Hairpulling
	# ensues.

	# The code below seems to follow, roughly, the path of
	#   client.login
	#   -> baseclient.login
	#     -> login_helpers.login
	#        -> uaaclient.authorize
	#           -> uaaclient.authenticate_with_password_grant
	#              -> token_issuer.owner_password_grant
	#                 -> REST call somewhere inside
	# resulting in a token instance.
	#
	# There is a second path through
	#  uaaclient.authenticate_with_implicit_grant -> tokenissuer.implicit_grant_with_creds
	# which has not been traced and assimilated.
	#
	# The token_data attribute/accessor inside the token instance
	# takes the token string itself apart getting at some hidden data.
	# (Base-encoded json object)
	#
	# For new we do the same directly, and keep it here, in the client.

	set info [my info]

	# Pull the target for authentication requests out of the
	# target information. In contrast to v1 where authentication
	# happens under the regular CC API v2 allows redirection to a
	# separate authentication server

	set    authorizer [dict get $info authorization_endpoint]
	append authorizer /oauth/token

	set query [http::formatQuery       \
		       grant_type password \
		       username   $user    \
		       password   $password]

	try {
	    # Custom headers for the authorizer
	    dict set authheaders AUTHORIZATION "Basic Y2Y6"
	    dict set authheaders Accept "application/json;charset=utf-8"

	    my configure -headers $authheaders

	    # Using raw POST to prevent auto-application of the
	    # standard REST baseurl.
	    lassign [my DoRequest POST $authorizer \
			 "application/x-www-form-urlencoded;charset=utf-8" \
			 $query] \
		code data _
	} finally {
	    my configure -headers $myheaders
	}

	# The response is a json object (plain dictionary).
	try {
	    set response [json::json2dict $data]
	} on error {e o} {
	    return -code error -errorcode {STACKATO SERVER DATA ERROR} \
		"Received invalid JSON from server; Error: $e"
	}

	debug.v2/client {ri = ($response)}

        # Expected keys:
        # - access_token        base64 encoded token
        # - token_type          "bearer", fixed
        # - refresh_token       == access_token, so far
        # - expires_in          some sort of timestamp
        # - scope               list of permissions?
        # - jti                 ???
        dict with response {}

	# Currently only using access_token and token_type.

	# Note: Standard v2 API does not provide an ssh key.
	# Only a token. And we have to assemble it.

	set myuser       $user
	set myauth_token "$token_type $access_token"

	debug.v2/client {token = ($myauth_token)}

	my decode_token $access_token

	return [list $myauth_token]
    }

    method change_password {new_password old_password} {
	debug.v2/client {}

	set info [my info]
	set user [dict get $info user]

	my UAA PUT /Users/$user/password \
	    [jmap map dict \
		 [dict create \
		      password    $new_password \
		      oldPassword $old_password]]

	# We ignore the response, for now
	return
    }

    method uaa_add_user {email password} {
	debug.v2/client {}

	set response [my UAA POST /Users \
	  [jmap v2uconfig \
	       [dict create \
		    userName $email \
		    emails [list [dict create value $email]] \
		    name [dict create \
			      givenName $email \
			      familyName $email] \
		    password $password]]]

	debug.v2/client {==> [jmap v2-uaa-user $response]}

	# Result is the UUID the new UAA user is known under.
	return [dict get $response id]
    }

    method uaa_get_user {uuid} {
	debug.v2/client {}
	return [my UAA GET /Users/$uuid {}]
    }

    method uaa_delete_user {uuid} {
	debug.v2/client {}
	return [my UAA DELETE /Users/$uuid {}]
    }

    method uaa_list_users {} {
	debug.v2/client {}
	return [dict get [my UAA GET /Users {}] resources]
    }

    # # ## ### ##### ######## #############
    ## Entity Listing support
    # # ## ### ##### ######## #############

    # TODO: list resources of a specified type (pagination, search, ...).

    method filtered-of {type key value {depth 0}} {
	debug.v2/client {}

	set url /v2/$type
	append url ?q=${key}:${value}
	if {$depth > 0} {
	    append url &inline-relations-depth=$depth
	}

	return [my list-by-url $url]
    }

    method list-of {type {depth 0}} {
	debug.v2/client {}
	return [my list-by-url /v2/$type $depth]
    }

    method list-by-url {url {depth 0}} {
	debug.v2/client {}

	if {$depth > 0} {
	    append url ?inline-relations-depth=$depth
	}

	set result {}
	while {1} {
	    debug.v2/client {<== $url}

	    set page [my json_get $url]

	    foreach item [dict get $page resources] {
		set obj [stackato v2 get-for $item]
		lappend result [$obj url]
	    }

	    set url [dict get $page next_url]
	    if {$url eq "null"} break
	}

	return $result
    }

    # # ## ### ##### ######## #############
    ## Entity support
    # # ## ### ##### ######## #############

    method get-by-url {url args} {
	debug.v2/client {}
	#TODO load - handle query args (inlined depth etc.)

	try {
	    set result [my Request GET $url application/json]
	} trap {REST REDIRECT} {e o} {
	    return -code error -errorcode {STACKATO CLIENT BAD-RESPONSE} \
		"Can't parse unexpected redirection into JSON [lindex $e 1]"
	}

	try {
	    set response [json::json2dict [lindex $result 1]]
	} on error {e o} {
	    return -code error -errorcode {STACKATO SERVER DATA ERROR} \
		"Received invalid JSON from server; Error: $e"
	}

	return $response
    }

    method create-for-type {type json} {
	debug.v2/client {}
	try {
	    lassign [my Request POST /v2/$type application/json $json] _ result _
	} trap {REST REDIRECT} {e o} {
	    # Ignore the redirect, and process as if we got 200 OK.
	    lassign $e code where headers result
	}

	try {
	    set response [json::json2dict $result]
	} on error {e o} {
	    return -code error -errorcode {STACKATO SERVER DATA ERROR} \
		"Received invalid JSON from server; Error: $e"
	}

	return $response
    }

    method change-by-url {url json} {
	debug.v2/client {}
	try {
	    set result [my Request PUT $url application/json $json]
	} trap {REST REDIRECT} {e o} {
	    return -code error -errorcode {STACKATO CLIENT BAD-RESPONSE} \
		"Can't parse response into JSON [lindex $e 1]"
	}

	lassign $result _ result headers

	try {
	    set response [json::json2dict $result]
	} on error {e o} {
	    return -code error -errorcode {STACKATO SERVER DATA ERROR} \
		"Received invalid JSON from server; Error: $e"
	}

	return [list $response $headers]
    }

    method delete-by-url {url} {
	debug.v2/client {}
	my Request DELETE $url
    }

    method link {url type uuid} {
	debug.v2/client {}

	append url / ${type} s/ $uuid
	debug.v2/client { url = $url }

	try {
	    lassign [my Request PUT $url] _ result _
	} trap {REST REDIRECT} {e o} {
	    # Ignore the redirect, and process as if we got 200 OK.
	    lassign $e code where headers result
	}

	try {
	    set response [json::json2dict $result]
	} on error {e o} {
	    return -code error -errorcode {STACKATO SERVER DATA ERROR} \
		"Received invalid JSON from server; Error: $e"
	}

	return $response
    }

    method unlink {url type uuid} {
	debug.v2/client {}

	append url / ${type} s/ $uuid
	debug.v2/client { url = $url }

	try {
	    lassign [my Request DELETE $url] _ result _
	} trap {REST REDIRECT} {e o} {
	    # Ignore the redirect, and process as if we got 200 OK.
	    lassign $e code where headers result
	}

	try {
	    set response [json::json2dict $result]
	} on error {e o} {
	    return -code error -errorcode {STACKATO SERVER DATA ERROR} \
		"Received invalid JSON from server; Error: $e"
	}

	return $response
    }

    ## change -- collection-method add|replace for relations. type specific.

    # # ## ### ##### ######## #############
    ## Miscellanea

    method instances-of {url} {
	debug.v2/client {}
	return [my json_get $url/instances]
	# result = dict (id -> instance), where
	# instance = dict (k -> v)
    }

    method crashes-of {url} {
	debug.v2/client {}
	my json_get $url/crashes
    }

    method stats-of {url} {
	debug.v2/client {}
	my json_get $url/stats
    }

    method files {url path {instance 0}} {
	debug.v2/client {}
	try {
	    lindex [my http_get $url/instances/$instance/files/[ncgi::encode $path]] 1
	} trap {REST REDIRECT} {e o} {
	    set new [lindex $e 1]
	    debug.v2/client {==> $new}

	    lindex [my http_get_raw $new] 1
	}
    }

    # # ## ### ##### ######## #############
    ## State

    # # ## ### ##### ######## #############
    ## Internal support

    method json_get {url} {
	debug.v2/client {}
	try {
	    set result [my http_get $url application/json]
	} trap {REST REDIRECT} {e o} {
	    return -code error -errorcode {STACKATO CLIENT BAD-RESPONSE} \
		"Can't parse response into JSON [lindex $e 1]"
	}

	try {
	    set response [json::json2dict [lindex $result 1]]
	} on error {e o} {
	    return -code error -errorcode {STACKATO SERVER DATA ERROR} \
		"Received invalid JSON from server; Error: $e"
	}

	return $response

	#rescue JSON::ParserError
	#raise BadResponse, "Can't parse response into JSON", body
    }

    method http_get_raw {url {content_type {}}} {
	debug.v2/client {}
	# Using lower-level method, prevents system from prefixing our
	# url with the target server. This method allows the callers
	# to access any url they desire.

	my DoRequest GET $url $content_type
    }

    method http_get {path {content_type {}}} {
	debug.v2/client {}
	my Request GET $path $content_type
    }

    method http_post {path payload {content_type {}}} {
	debug.v2/client {}
	# payload = channel|literal
	my Request POST $path $content_type $payload
    }

    method http_put {path payload {content_type {}}} {
	debug.v2/client {}
	# payload = channel|literal
	my Request PUT $path $content_type $payload
    }

    method http_delete {path} {
	debug.v2/client {}
	my Request DELETE $path
    }

    method UAA {method url query} {
	debug.v2/client {}
	set info [my info]

	# Pull the actual target for UAA requests out of the target
	# information. In contrast to v1 where this happens under the
	# regular CC API v2 allows redirection to a separate user
	# server. Which can be different from the initial
	# authentication server also.

	set    uaa [dict get $info token_endpoint]
	append uaa $url

	debug.v2/client {uaa = $uaa}

	set savedflag [my cget -accept-no-location]

	try {
	    # Custom headers for the ucreator
	    dict set authheaders AUTHORIZATION $myauth_token
	    dict set authheaders Accept "application/json;charset=utf-8"

	    my configure -headers $authheaders -accept-no-location 1

	    # Using raw POST to prevent auto-application of the
	    # standard REST baseurl.
	    lassign [my DoRequest $method $uaa \
			 "application/json;charset=utf-8" \
			 $query] \
		code data _
	} finally {
	    my configure -headers $myheaders -accept-no-location $savedflag
	}

	# The response is a json object (plain dictionary).
	try {
	    set response [json::json2dict $data]
	} on error {e o} {
	    return -code error -errorcode {STACKATO SERVER DATA ERROR} \
		"Received invalid JSON from server; Error: $e"
	}

	debug.v2/client {ri = ($response)}
	return $response
    }

    method Request {method path {content_type {}} {payload {}}} {
	# payload = channel|literal

	# PAYLOAD see update_app, is dict with file channel inside ?
	# How/where is that handled.

	try {
	    if {$content_type ne {}} {
		http::config -accept $content_type
	    } else {
		http::config -accept */*
	    }

	    set result [my DoRequest $method $mytarget$path \
			    $content_type $payload]
	    return $result

	} trap {REST HTTP} {e o} {
	    # e = response body, possibly json
	    # o = dict, -errorcode has status in list, last element.

	    set rstatus [lindex [dict get $o -errorcode] end]
	    set rbody   $e

	    if {[my request_failed $rstatus]} {
		# FIXME, old cc returned 400 on not found for file access
		if {$rstatus in {404 400}} {
		    my NotFound [my PEM $rstatus $rbody]
		} else {
		    my TargetError [my PEM $rstatus $rbody]
		}
	    }

	    # else rethrow
	    return {*}$o $e

	} trap {REST REDIRECT} {e o} {
	    # Rethrow
	    return {*}$o $e

	} trap {POSIX ECONNREFUSED} {e o} {
	    my BadTarget $e

	} on error {e o} {
	    if {
		[string match {*couldn't open socket*} $e]
	    } {
		# XXX Determine the error-code behind the message, so
		# XXX that we can trap it (better than string match).
		my BadTarget $e
	    }

	    my InternalError $e

	    #@todo rescue URI::Error, SocketError => e
	    #raise BadTarget, "Cannot access target (%s)" % [ e.message ]
	}
	return
    }

    method request_failed {status} {
	# Failed for 4xx and 5xx == range 400..599
	return [expr {(400 <= $status) && ($status < 600)}]
    }

    method PEM {status data} {
	debug.v2/client {}
	try {
	    set parsed [json::json2dict $data]
	    if {($parsed ne {}) &&
		[my HAS $parsed code] &&
		[my HAS $parsed description]} {

		set map [list "\"" {'}]
		set desc [string map $map [dict get $parsed description]]
		set errcode [dict get $parsed code]

		if {$errcode == 170002} {
		    debug.v2/client {staging progress}
		    # V2 -- Staging not finished. Generate an error
		    # specifically for this. Preempt generation of the
		    # outer NotFound error.
		    return -code error \
			-errorcode {STACKATO CLIENT V2 STAGING IN-PROGRESS} \
			$desc
		}

		if {$errcode == 170001} {
		    debug.v2/client {staging failed}
		    # V2 -- Staging failed. Generate an error
		    # specifically for this. Preempt generation of the
		    # outer NotFound error.
		    return -code error \
			-errorcode {STACKATO CLIENT V2 STAGING FAILED} \
			$desc
		}

		if {$errcode == 10003} {
		    debug.v2/client {permission error}
		    # V2 - Authentication/Permission error.
		    my AuthError $desc
		}

                if {$errcode == 310} {
                    # staging error is common enough that the user
                    # need not know the http error code behind it.
                    return "$desc"
                } else {
                    return "Error $errcode: $desc"
                }
	    } else {
		return "Error (HTTP $status): $data"
	    }
	} trap {STACKATO CLIENT V2} {e o} {
	    return {*}$o $e
	} on error {e o} {
	    if {$data eq {}} {
		return "Error ($status): No Response Received"
	    } else {
		#@todo: no trace => truncate
		#return "Error (JSON $status): $e"
		return "Error (JSON $status): $data"
	    }
	}
    }

    method HAS {dict key} {
	expr {[dict exists $dict $key] &&
	      ([dict get $dict $key] ne {})}
    }

    method BadTarget {text} {
	debug.v2/client {}
	return -code error -errorcode {STACKATO CLIENT V2 BADTARGET} \
	    "Cannot access target '$mytarget' ($text)"
    }

    method TargetError {msg} {
	debug.v2/client {}
	return -code error -errorcode {STACKATO CLIENT V2 TARGETERROR} $msg
    }

    method NotFound {msg} {
	debug.v2/client {}
	return -code error -errorcode {STACKATO CLIENT V2 NOTFOUND} $msg
    }

    method AuthError {{msg {}}} {
	debug.v2/client {}
	return -code error -errorcode {STACKATO CLIENT V2 AUTHERROR} $msg
    }

    # forward ...
    method internal {e} {
	my InternalError $e
    }

    method InternalError {e} {
	debug.v2/client {}
	return -code error -errorcode {STACKATO CLIENT V2 INTERNAL} \
	    [list $e $::errorInfo $::errorCode]
    }

    # # ## ### ##### ######## #############
}

# # ## ### ##### ######## ############# #####################
package provide stackato::v2::client 0
return