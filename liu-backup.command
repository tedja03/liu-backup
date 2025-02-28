#!/bin/zsh

# ============================================
# Name:     LiU Backup
# Author:   Ted Jangius
# ============================================

# Changelog:
# 1.2 - 2025-02-28
# - Enhanced the run_dialog function to handle various dialog variants.
# - Improved error handling and user feedback throughout the script.
# - Enhanced the script to handle OneDrive processes before starting the backup.
# - Added more detailed logging and progress updates for each step of the script.
# - Automated quitting System Settings once Full Disk Access has been granted to Terminal.

# 1.1 - 2025-02-20
# - Added a new version check and update mechanism for the script.
# - Added functionality to handle multiple user accounts for backup.
# - Added a cleanup function to remove temporary files and directories.
# - Enhanced the script to handle different system architectures (i386 and arm64).
# - Minor changes to script logic.

# 1.0 - 2025-02-10
# - Initial release

# Disable shellcheck for zsh-specific syntax, like:
# - quoting/double quoting to prevent globbing, word splitting, etc.
# - expanding arrays, and using parameter expansion flags
# - using the print command to output text
# - nested variable substitution
# shellcheck shell=bash disable=2086,2128,2206,2231,2299

set_variables() {
    clear
    product_name="LiU Backup"
    version="1.2"
    print_output "$product_name $version launching …"
    script_name="${ZSH_ARGZERO:t}"
    script_path="${ZSH_ARGZERO:a}"
    script_folder="${ZSH_ARGZERO:h:a}"
    dialog_path="/usr/local/bin/dialog"
    app_support_folder="/Library/Application Support"
    banner_path="$app_support_folder/LiU/Branding/liu_white_blue_1200x200_banner.png"
    alt_banner_path="color=#00cfb5"
    case $EUID in
    0)
        if ! [ -d ${1:-none} ] ; then
            error_output 2 "Don't run this script as $USER, exiting …"
        fi
        tmp_dir=$1;;
    *)
        tmp_dir=$(mktemp -d "/tmp/$script_name.XXXXXX");;
    esac
    can_eacas=false
    case $(/usr/bin/arch) in
    i386)
        if system_profiler SPiBridgeDataType | grep -q "Apple T2 Security"; then
            can_eacas=true
        fi;;
    arm64)
        can_eacas=true;;
    esac
    arguments_json="$tmp_dir/${script_name}_arguments.json"
    command_file="$tmp_dir/${script_name}.log"
    default_command_file="/var/tmp/dialog.log"
    if ! [ -x $dialog_path ]; then
        error_output 11 "Unable to find dialog executable, exiting …"
    fi
    current_user=$USER
    if ! /usr/bin/dsmemberutil checkmembership -U $current_user -G admin | grep -q "user is a member of the group"; then
        run_dialog nonadmin
        error_output 
    fi
    terminal_app_name="Terminal"
    utilities_folder="/System/Applications/Utilities"
    terminal_app_path="$utilities_folder/$terminal_app_name.app"
    permission="Full Disk Access"
    # list of users with home folders in /Users not owned by root, returning only the username, one per line
    # shellcheck disable=2206,2296
    users_from_folders=(${(@f)$(print -l /Users/[^_]*(^u:root:))##*/})
    case ${#users_from_folders} in
    0)
        error_output 12 "No user accounts found, exiting …";;
    [1-9])
        if [ $EUID -eq 0 ]; then
            print_output "${#users_from_folders} users found"
        fi;;
    *)
        error_output 5 "Too many user accounts found, exiting …";;
    esac
    prefs_panel_path="x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
}

# Prints a message to the terminal prefixed with the current user
print_output() {
    print -- "[${USER:l}] $*"
}

# Prints an error message to the terminal and exits
error_output() {
    code=${?:=1}; shift
    case $code in
    1)
        print_output "Unhandled runtime error, exiting …";;
    *)
        print -- "[${USER:l}] $*"
    esac
    exit $code
}

# Run dialog with the provided arguments
run_dialog() {
    variant=$1; shift
    json_arguments='
        "titlefont": "name=KorolevLiU",
        "ontop": true,
        "moveable": true,'
    case $variant in
    process)
        subvariant=$1; shift
        message=(
            "Welcome to **$product_name**.<br><br>Please"
            "save any documents and close all applications,"
            "*except $terminal_app_name*, before continuing.")
        init_item='{
            "title": "Script initialization",
            "icon": "SF=gear.badge.questionmark,color=#00bcec",
            "status": "success",
            "statustext": "Complete",
            "subtitle": "Script is launched and ready to run"}'
        permission_item='{
            "title": "'$permission'",
            "icon": "SF=externaldrive.badge.questionmark,color=#00bcec",
            "status": "pending",
            "statustext": "Pending",
            "subtitle": "'$product_name' requires '$permission'"}'
        user_item='{
            "title": "Backup source selection",
            "icon": "SF=person.crop.circle.badge.questionmark,color=#00bcec",
            "status": "pending",
            "statustext": "Pending",
            "subtitle": "Select user account(s) to backup"}'
        target_item='{
            "title": "Backup destination",
            "icon": "SF=folder.fill.badge.plus,color=#00bcec",
            "status": "pending",
            "statustext": "Pending",
            "subtitle": "Writability and space requirements"}'
        backup_item='{
            "title": "Perform backup",
            "icon": "SF=externaldrive.badge.timemachine,color=#00bcec",
            "status": "pending",
            "statustext": "Pending",
            "subtitle": "Executing the backup job"}'
        next_steps_item='{
            "title": "Next steps",
            "icon": "SF=gear.badge.questionmark,color=#00bcec",
            "status": "pending",
            "statustext": "Pending",
            "subtitle": "Migration or reinstall"}'
        case $subvariant in
        first)
            sudo_item='{
                "title": "Script privileges",
                "icon": "SF=apple.terminal,color=#00bcec",
                "status": "pending",
                "statustext": "Pending",
                "subtitle": "'$product_name' needs elevation to run properly"}'
            json_arguments+='
                "progresstext": "Ready to start …",
                "button1text": "Let'\''s go",';;
        second)
            sudo_item='{
                "title": "Script privileges",
                "icon": "SF=apple.terminal,color=#00bcec",
                "status": "wait",
                "statustext": "Waiting",
                "subtitle": "'$product_name' needs elevation to run properly"}'
            json_arguments+='
            "progresstext": "Waiting for authentication …",
            "button1disabled": true,
            "button1text": "Wait",';;
        esac
        listitem=(
            $init_item $sudo_item $permission_item
            $user_item $target_item $backup_item $next_steps_item)
        json_arguments=${json_arguments//bottom/bottomright}
        # shellcheck disable=2296
        json_arguments+='
            "bannerimage": "'$banner_path'",
            "listitem": ['${(j:,:)listitem}'],
            "liststyle": "compact",
            "infotext": "Version '$version'",
            "position": "right",
            "positionoffset": "150",
            "message": "'$message'",
            "bannertitle": "'$product_name'",
            "icon": "SF=externaldrive.badge.timemachine,color=#00bcec",
            "button2text": "Cancel",
            "progress": '${#listitem:-7}',
            "height": "775"';;
    nonadmin)
        message=(
            "This script requires elevated privileges to run properly."
            "<br><br>Please run the script from a local administrator account.")
        json_arguments+='
            "bannerimage": "'$alt_banner_path'",
            "width": "600",
            "height": "400",
            "button1text": "Cancel",
            "message": "'${message}'",
            "bannertitle": "Missing permissions",
            "icon": "SF=person.badge.key,color=#00bcec"';;
    unauthorized)
        message=("Failed to authenticate correctly three times, aborting …")
        json_arguments+='
            "bannerimage": "'$alt_banner_path'",
            "width": "600",
            "height": "400",
            "button1text": "OK",
            "timer": 3,
            "message": "'${message}'",
            "bannertitle": "Authentication failed 3 times",
            "icon": "SF=person.badge.key,color=#00bcec"';;
    timeout)
        message=(
            "A timeout was reached waiting for Terminal to be granted $permission."
            "<br><br>Please run the script again and grant $permission to $terminal_app_name.")
        json_arguments+='
            "bannerimage": "'$alt_banner_path'",
            "width": "600",
            "height": "400",
            "button1text": none,
            "button2text": "Cancel",
            "message": "'${message}'",
            "bannertitle": "Permissions timeout",
            "icon": "SF=person.badge.key,color=#00bcec"';;
    authenticate)
        attempts=$1
        pass_field='"title": "Password", "name": "password", "secure": true, "required": true, "prompt": "Password for '$current_user'"'
        admin_field='"label" : "Is a member of the admin group", "checked" : true, "disabled" : true'
        base_message="**$product_name** requires elevation."
        message=(
            $base_message
            "<br><br>Please authenticate as \`$current_user\`:")
        if [ $attempts -lt 3 ]; then
            message=(
                $base_message
                "<br><br>**Failed** to authenticate \`$current_user\`, try again:")
        fi
        json_arguments+='
            "bannerimage": "'$alt_banner_path'",
            "width": "600",
            "height": "400",
            "button1text": "Authenticate",
            "button2text": "Cancel",
            "infobox": "**Attempts left**<br>'$attempts'/3",
            "checkbox": [{'$admin_field'}],
            "textfield": [{'$pass_field'}],
            "message": "'${message}'",
            "bannertitle": "Elevated permissions required",
            "icon": "SF=person.badge.key,color=#00bcec",
            "vieworder": "textfield,checkbox"';;
    permissions)
        message=(
            "Would you like to open **System Settings** to more easily grant **$terminal_app_name** the required"
            "permissions?<br><br>#### Note<br>When the correct permissions are identified, System Settings will be quit"
            "and the process will continue.")
        json_arguments+='
            "width": "600",
            "height": "500",
            "timer": 120,
            "bannerimage": "'$alt_banner_path'",
            "bannertitle": "'$permission' required",
            "icon": "'$terminal_app_path'",
            "message": "'${message}'",
            "button1text": "Open",
            "button2text": "Cancel"';;
    user_selection)
        message=("Select a user account to backup:")
        # shellcheck disable=2296
        values='"values": ["'${(j:",":)users_from_folders}'","---","All users above"]'
        selectitems='"title": "User", "required": true, '$values', "default": "'${users_from_folders[1]}'"'
        json_arguments+='
            "width": "600",
            "height": "400",
            "timer": 120,
            "bannerimage": "'$alt_banner_path'",
            "button1text": "Select",
            "button2text": "Cancel",
            "selectitems": [{'$selectitems'}],
            "message": "'${message}'",
            "bannertitle": "Choose backup source",
            "icon": "SF=person.fill.questionmark,color=#00bcec"';;
    no_space)
        message=(
            "Not enough space on target disk to perform backup."
            "| Space | Value |<br>"
            "| :--- | :--- |<br>"
            "| Required | $space_req_string |<br>"
            "| Free | $space_free_string |<br>")
        json_arguments+='
            "width": "600",
            "height": "400",
            "bannerimage": "'$alt_banner_path'",
            "bannertitle": "Not enough space",
            "button1text": "Cancel",
            "icon": "SF=externaldrive.badge.xmark,color=#00cfb5",
            "message": "'${message}'"';;
    ready)
        message=(
            "| Space | Value |<br>"
            "| :--- | :--- |<br>"
            "| Required | $space_req_string |<br>"
            "| Free | $space_free_string |<br>")
        message+=("<br><br>We're all set to start the backup process.")
        if [ $total_space_percent -gt 90 ]; then
            print_output "Warning: backup will take up nearly all available disk space on target"
            print_output "After backup, less than $((100-total_space_percent))% will be available"
            message+=(
                "<br><br>**Warning**<br>Backup will take up nearly all available disk space on target."
                "After backup, less than $((100-total_space_percent))% will be available on the target disk.")
            height=500
        fi
        json_arguments+='
            "width": "600",
            "height": "'${height:-400}'",
            "bannerimage": "'$alt_banner_path'",
            "timer": 120,
            "button1text": "Start",
            "button2text": "Cancel",
            "message": "'${message}'",
            "bannertitle": "Ready to backup",
            "icon": "SF=externaldrive.badge.timemachine,color=#00cfb5"';;
    next_steps)
        message=("The backup process has completed successfully."
            "<br>At this point, you can choose to attempt a migration through Jamf, or reinstall macOS.")
        if [ $can_eacas = true ]; then
            message+=(
                "<br><br>**Note**<br>To use the Erase Assistant you will have to authenticate again.")
            button1text="Attempt a migration …"
            button2text="Quit $product_name"
            infobuttontext="Launch Erase Assistant"
            json_arguments+='
                "infobuttontext": "'$infobuttontext'",'
        else
            message+=(
                "<br><br>**Note**<br>The Erase Assistant is not available on this computer model."
                "Please use Recovery Mode to erase the computer.")
            button1text="Attempt a migration …"
            button2text="Quit $product_name"
        fi
        json_arguments+='
            "width": "600",
            "height": "400",
            "bannerimage": "'$alt_banner_path'",
            "bannertitle": "Backup completed",
            "button1text": "'$button1text'",
            "button2text": "'$button2text'",
            "icon": "SF=externaldrive.badge.checkmark,color=#00bcec",
            "message": "'$message'"';;
    update)
        message=("<br>&nbsp;<br>Would you like to update?")
        json_arguments+='
            "width": "400",
            "height": "350",
            "bannerimage": "'$alt_banner_path'",
            "bannertitle": "'$product_name' '$new_version' available",
            "infotext": "Version '$version'",
            "button1text": "Yes",
            "button2text": "Skip",
            "icon": "SF=icloud.and.arrow.down,color=#00cfb5",
            "message": "'${message}'"';;
    update_complete)
        message=(
            "$product_name has been updated to version $new_version."
            "<br><br>Please restart $product_name to use the new version.")
        json_arguments+='
            "width": "600",
            "height": "400",
            "bannerimage": "'$alt_banner_path'",
            "bannertitle": "Update complete",
            "button1text": "Quit",
            "icon": "SF=arrow.down.circle,color=#00cfb5",
            "message": "'${message}'"';;
    esac
    print "{$json_arguments}" > $arguments_json
    /bin/sleep 0.1
    case $variant in
    process)
        $dialog_path --commandfile $command_file --jsonfile $arguments_json 2> /dev/null & /bin/sleep 0.1
        dialog_pid=$!
        case $subvariant in
        first)
            print "progresstext: Waiting …" >> $command_file
            /bin/sleep 2
            print "progress: 1" >> $command_file
            wait $dialog_pid
            case $? in
            0)
                run_dialog process second
                dialog_pid=$!
                /bin/sleep 1
                print "progress: 1" >> $command_file;;
            2|10)
                error_output 6 "User cancelled process with GUI, exiting …";;
            *)
                error_output 1;;
            esac
        esac;;
    permissions)
        $dialog_path --jsonfile $arguments_json 2> /dev/null
        return $?;;
    *)
        captured_input=$($dialog_path --jsonfile $arguments_json 2> /dev/null)
        dialog_exit_code=$?
        case $variant in
        authenticate)
            inputted_password=$(print -- $captured_input | awk -F': ' 'tolower($0) ~ /password/ {print $NF}');;
        user_selection)
            selected_user=$(print -- $captured_input | awk -F': ' '/SelectedOption/ {print $NF}' | tr -d \")
            case $selected_user in
            "All users above")
                selected_user=all;;
            esac;;
        next_steps)
            migrate_answer=$dialog_exit_code
            return;;
        update)
            update_exit_code=$dialog_exit_code
            return $update_exit_code;;
        esac
        case $dialog_exit_code in
        0)
            case $variant in
            nonadmin)
                error_output 0 "Script needs to be run from a local administrator account";;
            erase)
                if [ $can_eacas = false ]; then
                    error_output 0 "Erase Assistant not available, exiting …"
                fi;;
            update)
                return $dialog_exit_code;;
            esac;;
        # cancelled or quitkey
        2|10)
            error_output 6 "User cancelled process with GUI, exiting …";;
        4)
            error_output 4 "Timeout reached, exiting …";;
        *)
            error_output 1;;
        esac;;
    esac
}

# Initialize the script
script_init() {
    # Check if the script is running as root
    case $EUID in
    0)
        print_output "Initializing elevated functions …"
        return 0;;
    *)
        print_output "Initializing non-elevated functions …"
        run_dialog process first;;
    esac
}

# Display a dialog to authenticate the user
elevate_script() {
    if ! sudo -Nnv &> /dev/null; then
        print_output "$product_name requires root privileges - showing GUI to authenticate …"
        attempts=3
        while [ $attempts -gt 0 ]; do
            unset inputted_password
            run_dialog authenticate $attempts
            if /usr/bin/dscl . -authonly $current_user $inputted_password &> /dev/null; then
                # shellcheck disable=2296
                if print -n -- ${(q)inputted_password} | sudo -Sp "" true &> /dev/null; then
                    print_output "Password for $current_user is correct, continuing …"
                    password_correct=true
                    break
                fi
            fi
            print_output "Password for $current_user is incorrect, try again …"
            ((attempts--))
        done
        if [ $attempts -eq 0 ]; then
            run_dialog unauthorized
            error_output 3 "Too many invalid attempts, exiting …"
        fi
    else
        print_output "Elevated privileges already present, continuing …"
        already_sudo=true
    fi
    if [ ${already_sudo:=false} = true ]; then
        sudo $script_path $tmp_dir
    elif [ ${password_correct:=false} = true ]; then
        print_output "Elevated privileges granted, continuing …"
        print $inputted_password | sudo -Sp "" $script_path $tmp_dir
    else
        print_output "Unable to authenticate user using GUI, trying osascript …"
        /usr/bin/osascript -e 'do shell script "'$script_path $tmp_dir'" with administrator privileges'
    fi
}

# Display a progress indicator while a process is running
show_progress() {
    backup_pid=${1:-0}
    print_output "Monitoring backup progress in $backup_log …"
    local progress=(⣼ ⣹ ⢻ ⠿ ⡟ ⣏ ⣧ ⣶)
    local i=0
    while /bin/ps -p $backup_pid > /dev/null; do
        if [ $backup_pid -gt 0 ]; then
            # Read the latest line in log file
            new_output=$(/usr/bin/tail -n 1 $backup_log)
            if [[ "$new_output" != "$last_output" ]]; then
                last_output=$new_output
            fi
            if [ -z "$last_output" ]; then
                last_output="Backup in progress …"
            fi
            if [ ${#last_output} -gt 120 ]; then
                last_output="${last_output:0:120}…"
            fi
        fi
        if ! /usr/bin/pgrep -i dialog > /dev/null; then
            builtin kill -n 9 $$
        fi
        # Display progress indicator and output
        print -n "\r\033[K${progress[i % ${#progress[@]} + 1]} ${last_output}"
        print "progresstext: $last_output" >> $command_file
        /bin/sleep 0.1
        ((i++))
    done
}

# Update the progress
progress_update() {
    case $1 in
    authenticate)
        print "listitem: index: 1, status: success, statustext: Elevated" >> $command_file
        print "progress: increment" >> $command_file
        print "progresstext: ✔︎ Authenticated" >> $command_file
        /bin/sleep 1
        print "listitem: index: 2, status: wait, statustext: Processing …" >> $command_file
        print "progresstext: Awaiting $terminal_app_name being granted $permission …" >> $command_file;;
    permissions)
        print "listitem: index: 2, status: success, statustext: Granted" >> $command_file
        print "listitem: index: 2, icon: SF=externaldrive.badge.checkmark color=#00bcec" >> $command_file
        print "progress: increment" >> $command_file
        print "progresstext: ✔︎ $terminal_app_name has been granted $permission …" >> $command_file
        /bin/sleep 1
        print "listitem: index: 3, status: wait, statustext: Processing …" >> $command_file
        print "progresstext: Waiting for backup source selection …" >> $command_file
        ;;
    userselect)
        print "listitem: index: 3, status: success, statustext: Chosen" >> $command_file
        print "listitem: index: 3, subtitle: '$selected_user' selected" >> $command_file
        print "listitem: index: 3, icon: SF=person.crop.circle.badge.checkmark color=#00bcec" >> $command_file
        print "progress: increment" >> $command_file
        print "progresstext: ✔︎ Selection made ($selected_user)" >> $command_file
        /bin/sleep 1
        print "listitem: index: 4, status: wait, statustext: Processing …" >> $command_file
        print "progresstext: Verifying writability and space requirements …" >> $command_file;;
    ready)
        print "listitem: index: 4, status: success, statustext: Verified" >> $command_file
        print "listitem: index: 4, subtitle: …/${backup_folder:t}" >> $command_file
        print "progress: increment" >> $command_file
        print "progresstext: ✔︎ Backup target: $total_space_string" >> $command_file
        /bin/sleep 2
        print "listitem: index: 5, status: pending, statustext: Waiting …" >> $command_file
        print "progresstext: Waiting to start backup …" >> $command_file;;
    no_space)
        print "listitem: index: 4, status: error, statustext: Error" >> $command_file
        print "progress: complete" >> $command_file
        print "progresstext: ✘ Not enough space, $total_space_string" >> $command_file;;
    going)
        print "listitem: index: 5, status: wait, statustext: Processing …" >> $command_file
        print "progress: increment" >> $command_file
        print "progresstext: Backup in progress …" >> $command_file
        /bin/sleep 1;;
    next_steps)
        print "listitem: index: 5, status: success, statustext: Complete" >> $command_file
        print "progress: increment" >> $command_file
        print "progresstext: ✔︎ Backup complete" >> $command_file
        /bin/sleep 1
        print "listitem: index: 6, status: wait, statustext: Processing …" >> $command_file
        print "progresstext: Waiting for answer …" >> $command_file;;
    last)
        case $migrate_answer in
        0)
            print "listitem: index: 6, status: success, statustext: Done" >> $command_file
            print "progress: increment" >> $command_file
            print "listitem: index: 4, subtitle: Jamf Connect migration" >> $command_file
            print "progresstext: ✔︎ Jamf Connect migration selected …" >> $command_file
            /bin/sleep 1
            print "listitem: index: 7, status: wait, statustext: Processing …" >> $command_file
            print "progresstext: Attempting Jamf Connect migration …" >> $command_file;;
        2)
            print "listitem: index: 6, status: success, statustext: Done" >> $command_file
            print "progress: complete" >> $command_file
            print "progresstext: ✔︎ Backup complete, quitting …" >> $command_file
            /bin/sleep 1;;
        3)
            print "listitem: index: 6, status: success, statustext: Done" >> $command_file
            print "progress: increment" >> $command_file
            print "listitem: index: 4, subtitle: Erase Assistant" >> $command_file
            print "progresstext: ✔︎ Erase Assistant selected" >> $command_file
            /bin/sleep 1
            print "listitem: index: 7, status: wait, statustext: Processing …" >> $command_file
            print "progresstext: Launching Erase Assistant …" >> $command_file;;
        esac;;
    esac
}

# Evaluate if the script has $permission
evaluate_full_disk_access() {
    # Check if the specified application has $permission
    get_full_disk_access_status() {
        bundle_id="com.apple.Terminal"
        command="/usr/bin/sqlite3"
        db_path="/Library/Application Support/com.apple.TCC/TCC.db"
        query='select client from access where auth_value and service = "kTCCServiceSystemPolicyAllFiles"'
        if $command $db_path $query 2> /dev/null | grep -q $bundle_id; then
            return
        fi
        return 1
    }

    # Close System Preferences
    close_system_settings() {
        killall "System Settings" >/dev/null 2>&1
        killall "System Preferences" >/dev/null 2>&1
    }

    iteration=0
    while true; do
        # Check if the script has $permission
        if get_full_disk_access_status; then
            print "quit:" >> $default_command_file
            break
        fi
        /bin/sleep 1
        # Check if the dialog is still running
        if ! /usr/bin/pgrep -i dialog > /dev/null; then
            return 1
        fi
        ((iteration++)) 
        minutes=$((iteration / 60))
        seconds=$((iteration % 60))
        if [ $iteration -gt 3 ]; then
            print -n "\r\033[KAwaiting permission (max 2 minutes) … [${minutes}m ${seconds}s elapsed]"
        fi
        if [ $iteration -gt 120 ]; then
            run_dialog timeout
            error_output 4 "Timeout reached waiting for $permission, exiting …"
        fi
    done &
    /bin/sleep 0.5
    while [ ${question_answered:-false} = false ]; do
        if get_full_disk_access_status; then
            break
        fi
        if [ ${showed_dialog:-false} = false ]; then
            showed_dialog=true
            print_output "$permission required for $terminal_app_name, displaying dialog …"
            print_output "Upon identifying the correct permissions, System Settings will quit and the script continue …"
            run_dialog permissions
            case $? in
            0)
                print "button1: disable" >> $default_command_file
                print "button1text: Waiting …" >> $default_command_file
                print "message: Waiting for $permission to be granted …" >> $default_command_file
                print_output "Opening System Preferences."
                print_output "Please enable $terminal_app_name for $permission."
                /usr/bin/open $prefs_panel_path 2> /dev/null;;
                # /usr/bin/open -R "$terminal_app_path" 2> /dev/null;;
            4)
                error_output 4 "Timeout reached waiting for $permission, exiting …";;
            5)
                print_output "Permissions were granted without dialog interaction, continuing …"
                break;;
            *)
                error_output $? "User cancelled process with GUI, exiting …";;
            esac
        fi
        /bin/sleep 1
    done
    print "quit:" >> $default_command_file
    print_output "$terminal_app_name now has $permission, continuing …"
    # Click Later button, and quit System Settings
    close_system_settings
    print "activate: " >> $default_command_file
}

# Establish the user account to backup
establish_user() {
    print_output "Which account do you want to backup?"
    run_dialog user_selection
    print_output "User selection made: $selected_user"
}

# Create the backup target folder
create_backup_target() {
    # Converts bytes value to human-readable string [$1: bytes value]
    bytesToHumanReadable() {
        local i=${1:-0} d="" s=1 S=("Bytes" "KiB" "MiB" "GiB" "TiB" "PiB" "EiB" "YiB" "ZiB")
        while ((i > 1024 && s < ${#S[@]}-1)); do
            printf -v d ".%02d" $((i % 1024 * 100 / 1024))
            i=$((i / 1024))
            s=$((s + 1))
        done
        print "$i$d ${S[$s]}"
    }

    case $selected_user in
    all)
        computer_name=$(/usr/sbin/scutil --get ComputerName)
        computer_name=${${computer_name//[^[:ascii:]]/}// /_}
        backup_folder="$script_folder/backup_${computer_name}_${datestamp}";;
    *)
        backup_folder="$script_folder/backup_${selected_user}_${datestamp}";;
    esac
    datestamp=$(/bin/date $'+'$'%Y-%m-%d')
    case $selected_user in
    all)
        computer_name=$(scutil --get ComputerName)
        backup_folder="$script_folder/backup_${computer_name}_${datestamp}";;
    *)
        backup_folder="$script_folder/backup_${selected_user}_${datestamp}";;
    esac
    if [ -d $backup_folder ]; then
        print_output "Backup folder already exists, adding a timestamp to the folder name …"
        backup_folder="$backup_folder-$(date +%H.%M.%S)"
    fi
    print_output "Creating backup folder: $backup_folder"
    if ! /bin/mkdir -p $backup_folder; then
        error_output 7 "Unable to create backup folder, exiting …"
    fi
    if ! [ -w $backup_folder ]; then
        error_output 8 "Unable to write to backup folder, exiting …"
    fi
    # check if target has enough space
    space_free=$(/bin/df -k $backup_folder | awk 'NR==2 {print $4*1024}')
    space_req=0
    case $selected_user in
    all)
        for iterated_user in $users_from_folders; do
            user_space_req=$(du -Asck /Users/$iterated_user | awk '/total/ {print $1*1024}')
            space_req=$((user_space_req + space_req))
        done;;
    *)
        space_req=$(du -Asck $app_support_folder /Users/$selected_user | awk '/total/ {print $1*1024}');;
    esac
    applicationsupport_space_req=$(du -Asck $app_support_folder | awk '/total/ {print $1*1024}')
    space_req=$((applicationsupport_space_req + space_req))
    space_req_string=$(bytesToHumanReadable $space_req)
    space_free_string=$(bytesToHumanReadable $space_free)
    total_space_string="…/${backup_folder:t} (req: $space_req_string, avail: $space_free_string)"
    total_space_percent=$(print -- $((space_req * 100 / space_free)))
    if [[ $space_free -lt $space_req ]]; then
        progress_update no_space
        /bin/sleep 120
        error_output 9 "Not enough space on target, exiting …"
    fi
}

# Display the ready to run message
ready_to_run() {
    print_output "Please save any documents and close all applications, except Terminal.app, before continuing."
    run_dialog ready
}

# Run the backup process
run_backup() {
    backup_log="$backup_folder/backup_process.log"
    # Redirect output to a file
    {
        break_counter=0
        while pgrep OneDrive; do
            print "Checking for and quitting OneDrive processes"
            # for pid in $(/usr/bin/pgrep OneDrive); do
            #     kill -s QUIT $pid
            # done
            osascript -e 'quit app "OneDrive"'
            sleep 5
            if [ $break_counter -gt 6 ]; then
                print "OneDrive processes still running attempting to quit them for 30 seconds, exiting"
                return 1
            fi
            ((break_counter++))
        done
        sleep 1
        ditto="/usr/bin/ditto"
        case $selected_user in
        all)
            for iterated_user in $users_from_folders; do
                source_dir="/Users/$iterated_user"
                target_dir="$backup_folder/$iterated_user"
                /bin/mkdir -p $target_dir
                /bin/sleep 1
                for item in $source_dir/*(DN); do
                    print "Backing up '$item'"
                    /bin/mkdir -p $target_dir/${item:t}
                    $ditto -X --rsrc -v $item $target_dir/${item:t} &>/dev/null
                done
            done;;
        *)
            source_dir="/Users/$selected_user"
            target_dir="$backup_folder/$selected_user"
            /bin/mkdir -p "$target_dir"
            /bin/sleep 1
            # shellcheck disable=2231
            for item in $source_dir/*(DN); do
                print "Backing up '$item'"
                /bin/mkdir -p $target_dir/${item:t}
                $ditto -X --rsrc -v $item $target_dir/${item:t} &>/dev/null
            done;;
        esac
        target_dir="$backup_folder/Application Support"
        print "Backing up '$app_support_folder'"
        /bin/mkdir -p "$target_dir"
        /bin/sleep 1
        # shellcheck disable=2231
        for item in $app_support_folder/*(DN); do
            print "Backing up '$item'"
            /bin/mkdir -p $target_dir/${item:t}
            $ditto -X --rsrc -v $item $target_dir/${item:t} &> /dev/null
        done
        print "Setting permissions on '$backup_folder'"
        if ! /usr/sbin/chown -R 99:99 $backup_folder; then
            print "✘ Error setting permissions on '$backup_folder'"
        else
            print "✔︎ Permissions successfully set on backup folder"
        fi
        /bin/sleep 1
        print "Making a list of installed applications"
        /bin/sleep 1
        app_type="kMDItemContentTypeTree=com.apple.application-bundle"
        /usr/bin/mdfind $app_type -onlyin /Applications/ > "$backup_folder/application_list.txt"
    } > $backup_log &

    # Get the PID of the background process
    bg_pid=$!

    # Show progress indicator and output
    show_progress $bg_pid &
    # Wait for the background process to finish
    wait $bg_pid
    case $? in
    0)
        # Kill the progress indicator
        kill $!
        # Display the final output
        print_output "\nBackup process completed.";;
    137)
        error_output 6 "User cancelled process with GUI, exiting …";;
    *)
        error_output 1 "Backup process failed, exiting …";;
    esac
}

# Cleanup function
cleanup() {
    if [ -v command_file ]; then
        print "quit:" >> $command_file
    fi
    if [ $EUID -ne 0 ]; then
        print_output "Cleaning up $product_name run …"
        if [ -d $tmp_dir ]; then
            /bin/rm -rf $tmp_dir
        fi
    fi
}

# Ask the user if they want to migrate
next_steps() {
    run_dialog next_steps
}

# Run the Jamf Connect migration policy
run_migrate() {
    case $migrate_answer in
    0)
        print_output "Opening Self Service to the Jamf Connect migration policy …"
        /usr/bin/open "jamfselfservice://content?entity=policy&id=949&action=view";;
    esac
}

# Show the erase assistant
show_erase_assistant() {
    print_output "Launching Erase Assistant …"
    /usr/bin/open "/System/Library/CoreServices/Erase Assistant.app"
}

# Check for a new version of the script
check_for_update() {
    repo_url="https://raw.githubusercontent.com/tedja03/liu-backup/main/liu-backup.command"
    tmp_script_path=$tmp_dir/$script_name
    autoload is-at-least

    # Download the latest version of the script
    if /usr/bin/curl -s -o "$tmp_script_path" "$repo_url"; then
        new_version=$(/usr/bin/awk -F = '/^    version/ {print $NF}' $tmp_script_path | tr -d '"')
        # Compare the version of the downloaded script with the current script
        if ! is-at-least $new_version $version; then
            print_output "A new version ($new_version) of $product_name is available. You are running $version."
            run_dialog update
            case $? in
            0)
                print_output "Updating script to version $new_version …"
                if ! /bin/mv $script_path "$script_path.bak"; then
                    print_output "Unable to create backup of current script, exiting …"
                    exit 1
                fi
                if ! /bin/mv $tmp_script_path $script_path; then
                    print_output "Unable to update script, exiting …"
                    exit 1
                fi
                if ! /bin/chmod +x $script_path; then
                    print_output "Unable to set permissions on updated script, exiting …"
                    exit 1
                fi
                print_output "Script updated successfully."
                $script_path
                exit 0;;
            2)
                print_output "Skipping $product_name update …";;
            esac
        else
            print_output "You are running the latest version of the script."
        fi
    else
        return 1
    fi
}

# Main function
main() {
    set_variables $1
    if ! check_for_update; then
        error_output 1 "Unable to check for updates, continuing with the current version …"
    fi
    script_init
    case $EUID in
    0)
        print "listitem: 0: success" >> $command_file
        print_output "Running as root, continuing …";;
    *)
        elevate_script
        case $? in
        0)
            exit 0;;
        3)
            error_output 3 "Too many invalid selections, exiting …";;
        4)
            error_output 4 "Timeout reached waiting for $permission, exiting …";;
        5)
            error_output 5 "Too many user accounts found, please handle this computer manually …";;
        2|6|10|137)
            error_output 6 "User cancelled process with GUI, exiting …";;
        7)
            error_output 4 "Unable to create backup folder, exiting …";;
        8)
            error_output 7 "Unable to write to backup folder, exiting …";;
        9)
            error_output 8 "Not enough space on target, exiting …";;
        11)
            error_output 2 "Unable to find dialog binary, exiting …";;
        12)
            error_output 3 "No user folders found, exiting …";;
        *)
            error_output 1 "Unhandled runtime error, exiting …";;
        esac;;
    esac
    progress_update authenticate
    evaluate_full_disk_access
    progress_update permissions
    establish_user
    progress_update userselect
    create_backup_target
    progress_update ready
    ready_to_run
    progress_update going
    if ! run_backup; then
        error_output 1 "Backup process failed, exiting …"
    fi
    progress_update next_steps
    next_steps
    case $migrate_answer in
    0)
        progress_update migrate
        run_migrate;;
    2)
        progress_update last;;
    3)  
        progress_update erase
        show_erase_assistant;;
    esac
    cleanup
}

trap cleanup INT TERM EXIT
main $1