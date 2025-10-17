#!/bin/zsh
# shellcheck shell=bash disable=2086,2128,2206,2231,2299
#
# Disable shellcheck for zsh-specific syntax, like:
# - quoting/double quoting to prevent globbing, word splitting, etc.
# - expanding arrays, and using parameter expansion flags
# - using the print command to output text
# - nested variable substitution
#
# Name:     LiU Backup
# Author:   Ted Jangius
#
# Changelog:
#
# 1.4 - 2025-10-17
# - Performance optimizations in backup process.
# - Added retry logic to the backup process to handle transient errors.
# - Improved progress reporting during the backup process.
# - Enhanced error messages to provide more context on failures.
# 
# 1.3.2 - 2025-04-02
# - Minor typo in json string for update dialog caused update failures.
#
# 1.3.1 - 2025-04-02
# - Switched backup engine from ditto to rsync.
# - Added an exclusion for OneDrive's cache (<user_home>/Library/Group Containers/UBF8T346G9.OneDriveStandaloneSuite)
#       since it was causing issues with the backup process and/or calculating the backup size.
# - Changed the logic for how user folders are enumerated, and added support for the Shared folder, if it exists.
# - Fixed a bug where the dialog for Full Disk Access would not show.
#
# 1.3 - 2025-03-13
# - Fixed a bug with how the script enumerated required space for backup.
# - Added a warning if the backup size differs by more than 10% from the expected size.
# - Fixed a bug where the script would backup a user's Trash; this is now excluded.
# - Improved logic for numerous processes.
# - Small corrections to some dialog messages.
#
# 1.2.2 - 2025-03-07
# - Fixed a bug where the progrss indicator would spin backwards and improved its fluidity.
# - Changes so that all ditto commands are prefixed with caffeinate to prevent /bin/sleep.
#
# 1.2.1 - 2025-03-07
# - Fixed a bug where the script would not continue when unable to check for update.
#
# 1.2 - 2025-02-28
# - Enhanced the run_dialog function to handle various dialog variants.
# - Improved error handling and user feedback throughout the script.
# - Enhanced the script to handle OneDrive processes before starting the backup.
# - Added more detailed logging and progress updates for each step of the script.
# - Automated quitting System Settings once Full Disk Access has been granted to Terminal.
#
# 1.1 - 2025-02-20
# - Added a new version check and update mechanism for the script.
# - Added functionality to handle multiple user accounts for backup.
# - Added a cleanup function to remove temporary files and directories.
# - Enhanced the script to handle different system architectures (i386 and arm64).
# - Minor changes to script logic.
#
# 1.0 - 2025-02-10
# - Initial release
#

set_variables() {
    setopt extended_glob
    product_name="LiU Backup"
    version="1.4"
    script_name="${ZSH_ARGZERO:t}"
    script_path="${ZSH_ARGZERO:a}"
    script_folder="${ZSH_ARGZERO:h:a}"
    dialog_path="/usr/local/bin/dialog"
    app_support_folder="/Library/Application Support"
    banner_path="$app_support_folder/LiU/Branding/liu_white_blue_1200x200_banner.png"
    alt_banner_path="color=#00cfb5"
    print -nf '\e[8;30;120t'
    if (( EUID )); then
        clear
        print_output "$product_name $version launching"
        tmp_dir=$(mktemp -d "/tmp/$script_name.XXXXXX")
    else
        if ! [ -d ${1:-none} ] ; then
            error_output 2 "Don't run this script as $USER, exiting"
        fi
        tmp_dir=$1
        # list of users with home folders in /Users not owned by root,
        # returning only the username, one per line
        # shellcheck disable=2296
        users_from_folders=(${(@f)$(print -l /Users/^_*(^u:root:)):t})
        # add Shared folder to the list if it exists, but only if it has files in it
        if [ -d /Users/Shared ]; then
            if (( $(ls -l /Users/Shared | wc -l) )); then
                shared_folder_size=$(kbToHumanReadable $(du -sck /Users/Shared | awk '/\ttotal/ {print $1}'))
                users_from_folders+=("Shared")
            fi
        fi
        if ! (( ${#users_from_folders} )); then
            error_output 12 "No user accounts found, exiting"
        elif (( ${#users_from_folders} < 10 )); then
            print_output "${#users_from_folders} users found"
        else
            error_output 5 "Too many user accounts found, exiting"
        fi
    fi
    can_eacas=0
    case $(/usr/bin/arch) in
    i386)
        if system_profiler SPiBridgeDataType | grep -q "Apple T2 Security"; then
            can_eacas=1
        fi;;
    arm64)
        can_eacas=1;;
    esac
    arguments_json="$tmp_dir/${script_name}_arguments.json"
    command_file="$tmp_dir/${script_name}.log"
    default_command_file="/var/tmp/dialog.log"
    if ! [ -x $dialog_path ]; then
        error_output 11 "Unable to find dialog executable, exiting"
    fi
    current_user=$USER
    if ! /usr/bin/dsmemberutil checkmembership -U $current_user -G admin | grep -q "user is a member of the group"; then
        run_dialog nonadmin
        error_output 1 "Script needs to be run from a local administrator account, exiting"
    fi
    terminal_app_name="Terminal"
    utilities_folder="/System/Applications/Utilities"
    terminal_app_path="$utilities_folder/$terminal_app_name.app"
    permission="Full Disk Access"
    prefs_panel_path="x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    rsync_bin="/usr/bin/rsync"
    # Exclusions
    base_exclusions=(
        ".DS_Store"
        ".localized"
        ".Spotlight-V100"
        ".TemporaryItems"
        ".Trashes"
        "Desktop DB"
        "Desktop DF"
        "Network Trash Folder"
        "Temporary Items"
        "Thumbs.db"
        ".fseventsd"
        ".DocumentRevisions-V100"
        ".VolumeIcon.icns"
        ".com.apple.timemachine.donotpresent"
        ".AppleDouble"
        ".AppleDB"
        ".AppleDesktop"
        "._*"
        ".Trash"
        "*Cache*"
        "*OneDrive*"
    )
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
        print_output "Unhandled runtime error, exiting";;
    *)
        print -- "[${USER:l}] $*"
    esac
    exit $code
}

# Converts bytes value to human-readable string [$1: bytes value] (base10)
# also truncates to one decimal place and removes trailing .0
kbToHumanReadable() {
    local bytes=$1
    local kb=1000
    local units=(KB MB GB TB PB EB ZB YB)
    local i=1
    local value=$bytes

    while (( i < ${#units[@]} )); do
        # Use bc to compare value >= kb
        if (( $(print "$value >= $kb" | bc -l) )); then
            value=$(print "scale=1; $value / $kb" | bc -l)
            ((i++))
        else
            break
        fi
    done

    # Remove trailing .0
    value=${value%.0}
    printf "%s %s\n" "$value" "${units[i]}"
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
            "icon": "SF=folder.badge.plus,color=#00bcec",
            "status": "pending",
            "statustext": "Pending",
            "subtitle": "Verifying space requirements"}'
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
                "progresstext": "Ready to start",
                "button1text": "Let'\''s go",';;
        second)
            sudo_item='{
                "title": "Script privileges",
                "icon": "SF=apple.terminal,color=#00bcec",
                "status": "wait",
                "statustext": "Waiting",
                "subtitle": "'$product_name' needs elevation to run properly"}'
            json_arguments+='
            "progresstext": "Waiting for authentication",
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
            "icon": "SF=person.badge.key,'$alt_banner_path'"';;
    unauthorized)
        message=("Failed to authenticate correctly three times, aborting")
        json_arguments+='
            "bannerimage": "'$alt_banner_path'",
            "width": "600",
            "height": "400",
            "button1text": "OK",
            "timer": 3,
            "message": "'${message}'",
            "bannertitle": "Authentication failed 3 times",
            "icon": "SF=person.badge.key,'$alt_banner_path'"';;
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
            "icon": "SF=person.badge.key,'$alt_banner_path'"';;
    authenticate)
        attempts=$1
        pass_field='"title": "Password", "name": "password", "secure": true, "required": true'
        admin_field='"label" : "Member of the admin group", "checked" : true, "disabled" : true'
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
            "icon": "SF=person.badge.key,'$alt_banner_path'",
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
        values='"values": ["'$users_from_folders'"]'
        if (( ${#users_from_folders} > 1 )); then
            # shellcheck disable=2296
            values='"values": ["'${(j:",":)users_from_folders}'","---","All users above"]'
        fi
        # shellcheck disable=1009,1072,1073 # zsh-specific syntax
        if (( users_from_folders[(Ie)Shared] )); then
            json_arguments+='
                "checkbox": [
                    {
                        "label": "Include Shared folder (~'$shared_folder_size')",
                        "checked": false
                    }
                ],
                "vieworder": "dropdown, checkbox",'
        fi
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
            "icon": "SF=person.fill.questionmark,'$alt_banner_path'"';;
    no_space)
        message=(
            "| Space | Value |<br>"
            "| :--- | :--- |<br>"
            "| Required | $space_req_string |<br>"
            "| Free | $space_free_string |<br>")
        message+=("<br>Not enough space on target disk to perform backup.")
        json_arguments+='
            "width": "600",
            "height": "400",
            "bannerimage": "'$alt_banner_path'",
            "bannertitle": "Not enough space",
            "timer": 30,
            "button1text": "Abort",
            "icon": "SF=externaldrive.badge.xmark,palette=#ff6442,#00cfb5",
            "message": "'${message}'"';;
    ready)
        height=400
        timer='"timer": 120,'
        message=(
            "| Space | Value |<br>"
            "| :--- | :--- |<br>"
            "| Required | $space_req_string |<br>"
            "| Free | $space_free_string |<br>")
        message+=("<br>We're all set to start the backup process.")
        if pgrep -q OneDrive; then
            message+=(
                "<br><br>**Note**<br>OneDrive is currently running, but backing it up"
                "has proven problematic, and it is therefore **not included** in the backup."
                "Ensure that OneDrive has *fully* synced before proceeding as it will be terminated.")
            json_arguments+='
                "checkbox": [
                    {
                        "label": "I understand, continue …",
                        "enableButton1": true
                    }
                ],
                "button1disabled": true,'
            (( height += 150 ))
            timer=''
        fi
        if [ $total_space_percent -gt 90 ]; then
            print_output "Warning: backup will take up nearly all available disk space on target"
            print_output "After backup, less than $((100-total_space_percent))% will be available"
            message+=(
                "<br><br>**Warning**<br>Backup will take up nearly all available disk space on target."
                "After backup, less than $((100-total_space_percent))% will be available on the target disk.")
            (( height += 100 ))
        fi
        json_arguments+='
            '$timer'
            "width": "600",
            "height": "'$height'",
            "bannerimage": "'$alt_banner_path'",
            "button1text": "Start",
            "button2text": "Cancel",
            "message": "'${message}'",
            "bannertitle": "Ready to backup",
            "icon": "SF=externaldrive.badge.timemachine,'$alt_banner_path'"';;
    next_steps)
        message=("The backup process has completed successfully.")
        if (( backup_size_warning )); then
            message+=(
                "<br><br>**Note**<br>The backup size differs by more than 10% from the expected size."
                "Please verify that no important data is missing.<br>"
                "| Space | Value |<br>"
                "| :--- | :--- |<br>"
                "| Expected size | $lower_bound_string-$upper_bound_string |<br>"
                "| Backup size | $backup_size_string |<br>")
            next_steps_height=700
        fi
        message+=("<br><br>At this point, you can choose to attempt a migration through Jamf, or reinstall macOS.")
        if (( can_eacas )); then
            message+=(
                "<br><br>**Note**<br>To use the Erase Assistant you will have to authenticate again.")
            button1text="Attempt a migration"
            button2text="Quit $product_name"
            infobuttontext="Launch Erase Assistant"
            json_arguments+='
                "infobuttontext": "'$infobuttontext'",'
        else
            message+=(
                "<br><br>**Note**<br>The Erase Assistant is not available on this computer model."
                "Please use Recovery Mode to erase the computer.")
            button1text="Attempt a migration"
            button2text="Quit $product_name"
        fi
        json_arguments+='
            "width": "600",
            "height": "'${next_steps_height:-450}'",
            "bannerimage": "'$alt_banner_path'",
            "bannertitle": "Backup completed",
            "button1text": "'$button1text'",
            "button2text": "'$button2text'",
            "icon": "SF=externaldrive.badge.checkmark,'$alt_banner_path'",
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
            "icon": "SF=icloud.and.arrow.down,'$alt_banner_path'",
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
            "icon": "SF=arrow.down.circle,"'$alt_banner_path'",
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
            print "progresstext: Waiting" >> $command_file
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
                error_output 6 "User cancelled process with GUI, exiting";;
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
            if (( users_from_folders[(Ie)Shared] )); then
                include_shared=$(print -- $captured_input | awk -F': ' '/Include Shared folder/ {print $NF}' | tr -d \")
                if [[ $include_shared == "true" ]]; then
                    include_shared=1
                fi
            fi
            case $selected_user in
            "All users above")
                selected_user=all;;
            "Shared")
                selected_user=shared
                if (( include_shared )); then
                    include_shared=0
                fi;;
            esac;;
        next_steps)
            migrate_answer=$dialog_exit_code
            return;;
        update)
            update_exit_code=$dialog_exit_code
            return $update_exit_code;;
        no_space)
            abort_exit_code=$dialog_exit_code;;
        ready)
            if ((dialog_exit_code)); then
                cleanup_backup_target
            fi;;
        esac
        case $dialog_exit_code in
        0)
            case $variant in
            nonadmin)
                error_output 0 "Script needs to be run from a local administrator account";;
            erase)
                if ! (( can_eacas )); then
                    error_output 0 "Erase Assistant not available, exiting"
                fi;;
            update)
                return $dialog_exit_code;;
            no_space)
                return $abort_exit_code;;
            esac;;
        # cancelled or quitkey
        2|10)
            error_output 6 "User cancelled process with GUI, exiting";;
        4)
            error_output 4 "Timeout reached, exiting";;
        *)
            error_output 1;;
        esac;;
    esac
}

# Initialize the script
script_init() {
    # Check if the script is running as root
    if ! (( EUID )); then
        print_output "Initializing elevated functions"
        return 0
    fi
    print_output "Initializing non-elevated functions"
    run_dialog process first
    print "listitem: index: 0, icon: SF=gear.badge.checkmark color=#00bcec" >> $command_file
}

# Display a dialog to authenticate the user
elevate_script() {
    if ! sudo -Nnv &> /dev/null; then
        print_output "$product_name requires root privileges - showing GUI to authenticate"
        attempts=3
        while (( attempts )); do
            unset inputted_password
            run_dialog authenticate $attempts
            if /usr/bin/dscl . -authonly $current_user $inputted_password &> /dev/null; then
                # shellcheck disable=2296
                if print -n -- ${(q)inputted_password} | sudo -Sp "" true &> /dev/null; then
                    print_output "Password for $current_user is correct, continuing"
                    password_correct=1
                    break
                fi
            fi
            print_output "Password for $current_user is incorrect, try again"
            ((attempts--))
        done
        if ! (( attempts )); then
            run_dialog unauthorized
            error_output 3 "Too many invalid attempts, exiting"
        fi
    else
        print_output "Elevated privileges already present, continuing"
        already_sudo=1
    fi
    if (( already_sudo )); then
        sudo $script_path $tmp_dir
    elif (( password_correct )); then
        print_output "Elevated privileges granted, continuing"
        print $inputted_password | sudo -Sp "" $script_path $tmp_dir
    else
        print_output "Unable to authenticate user using GUI, trying osascript"
        /usr/bin/osascript -e 'do shell script "'$script_path $tmp_dir'" with administrator privileges'
    fi
}

# Display a progress indicator while a process is running
show_progress() {
    backup_pid=${1:-0}
    print_output "Monitoring progress in …/${backup_folder:t}/${backup_log:t}"
    local progress=(⣶ ⣧ ⣏ ⡟ ⠿ ⢻ ⣹ ⣼)
    local i=0
    while /bin/ps -p $backup_pid > /dev/null; do
        if (( backup_pid )); then
            # Read the latest line in log file
            new_output=$(/usr/bin/tail -n 1 $backup_log)
            if [[ "$new_output" != "$last_output" ]]; then
                last_output=$new_output
            fi
            if [ -z "$last_output" ]; then
                last_output="Backup in progress"
            fi
            if (( ${#last_output} > 120 )); then
                last_output="${last_output:0:120}"
            fi
        fi
        if ! /usr/bin/pgrep -i dialog > /dev/null; then
            builtin kill -9 $$
        fi
        # Display progress indicator and output
        print -n "\r\033[K${progress[i % ${#progress[@]} + 1]} ${last_output}"
        print "progresstext: $last_output" >> $command_file
        /bin/sleep 0.25
        ((i++))
    done
}

# Update the progress
progress_update() {
    case $1 in
    authenticate)
        print "listitem: index: 1, status: success, statustext: Elevated" >> $command_file
        print "listitem: index: 1, subtitle: Elevated privileges granted" >> $command_file
        print "progress: increment" >> $command_file
        print "progresstext: ✔︎ Authenticated" >> $command_file
        /bin/sleep 1
        print "listitem: index: 2, status: wait, statustext: Processing" >> $command_file
        print "progresstext: Awaiting $terminal_app_name being granted $permission" >> $command_file;;
    permissions)
        print "listitem: index: 2, status: success, statustext: Granted" >> $command_file
        print "listitem: index: 2, subtitle: $terminal_app_name granted $permission" >> $command_file
        print "listitem: index: 2, icon: SF=externaldrive.badge.checkmark color=#00bcec" >> $command_file
        print "progress: increment" >> $command_file
        print "progresstext: ✔︎ $terminal_app_name has been granted $permission" >> $command_file
        /bin/sleep 1
        print "listitem: index: 3, status: wait, statustext: Processing" >> $command_file
        print "progresstext: Waiting for backup source selection" >> $command_file
        ;;
    userselect)
        print "listitem: index: 3, status: success, statustext: Chosen" >> $command_file
        print "listitem: index: 3, subtitle: $selected_user selected" >> $command_file
        print "listitem: index: 3, icon: SF=person.crop.circle.badge.checkmark color=#00bcec" >> $command_file
        print "progress: increment" >> $command_file
        print "progresstext: ✔︎ Selection made ($selected_user)" >> $command_file
        /bin/sleep 1
        print "listitem: index: 4, status: wait, statustext: Calculating" >> $command_file
        print "progresstext: Verifying space requirements" >> $command_file;;
    ready)
        print "listitem: index: 4, status: success, statustext: Verified" >> $command_file
        print "listitem: index: 4, subtitle:${backup_folder:t}" >> $command_file
        print "progress: increment" >> $command_file
        print "progresstext: ✔︎ Backup folder: …/${backup_folder:t} • $total_space_string" >> $command_file
        /bin/sleep 2
        print "listitem: index: 5, subtitle: $space_req_string to backup" >> $command_file
        print "listitem: index: 5, status: pending, statustext: Waiting" >> $command_file;;
    no_space)
        print "listitem: index: 4, status: error, statustext: Error" >> $command_file
        print "listitem: index: 4, subtitle: Not enough space" >> $command_file
        print "progress: complete" >> $command_file
        print "progresstext: ✘ Not enough space, $total_space_string" >> $command_file;;
    unable_to_create)
        print "listitem: index: 4, status: error, statustext: Error" >> $command_file
        print "listitem: index: 4, subtitle: Unable to create backup folder" >> $command_file
        print "progress: complete" >> $command_file
        print "progresstext: ✘ Unable to create backup folder" >> $command_file
        /bin/sleep 10;;
    unable_to_write)
        print "listitem: index: 4, status: error, statustext: Error" >> $command_file
        print "listitem: index: 4, subtitle: Unable to write to backup folder" >> $command_file
        print "progress: complete" >> $command_file
        print "progresstext: ✘ Unable to write to backup folder" >> $command_file
        /bin/sleep 10;;
    going)
        print "listitem: index: 5, status: wait, statustext: Processing" >> $command_file
        print "progress: increment" >> $command_file
        print "progresstext: Backup in progress" >> $command_file
        /bin/sleep 1;;
    next_steps)
        print "listitem: index: 5, status: success, statustext: Complete" >> $command_file
        print "listitem: index: 5, subtitle: Backup complete" >> $command_file
        print "progress: increment" >> $command_file
        print "progresstext: ✔︎ Backup complete" >> $command_file
        /bin/sleep 1
        print "listitem: index: 6, status: wait, statustext: Waiting" >> $command_file
        print "progresstext: Waiting for answer" >> $command_file;;
    last)
        case $migrate_answer in
        0)
            print "listitem: index: 6, status: success, statustext: Done" >> $command_file
            print "progress: increment" >> $command_file
            print "listitem: index: 4, subtitle: Jamf Connect migration" >> $command_file
            print "progresstext: ✔︎ Jamf Connect migration selected" >> $command_file
            /bin/sleep 1
            print "listitem: index: 7, status: wait, statustext: Processing" >> $command_file
            print "progresstext: Attempting Jamf Connect migration" >> $command_file;;
        2)
            print "listitem: index: 6, status: success, statustext: Done" >> $command_file
            print "progress: complete" >> $command_file
            print "progresstext: ✔︎ Backup complete, quitting" >> $command_file
            /bin/sleep 1;;
        3)
            print "listitem: index: 6, status: success, statustext: Done" >> $command_file
            print "progress: increment" >> $command_file
            print "listitem: index: 4, subtitle: Erase Assistant" >> $command_file
            print "progresstext: ✔︎ Erase Assistant selected" >> $command_file
            /bin/sleep 1
            print "listitem: index: 7, status: wait, statustext: Processing" >> $command_file
            print "progresstext: Launching Erase Assistant" >> $command_file;;
        esac
        print "listitem: index: 7, icon: SF=gear.badge.checkmark color=#00bcec" >> $command_file;;
    esac
}

# Evaluate if the script has $permission
evaluate_full_disk_access() {
    # Check if the specified application has $permission
    get_full_disk_access_status() {
        bundle_id="com.apple.Terminal"
        command="/usr/bin/sqlite3"
        db_path="/Library/Application Support/com.apple.TCC/TCC.db"
        # shellcheck disable=2089
        query='select client from access where auth_value and service = "kTCCServiceSystemPolicyAllFiles"'
        # shellcheck disable=2090
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
        if (( iteration > 3 )); then
            print -n "\r\033[KAwaiting permission (max 2 minutes) [${minutes}m ${seconds}s elapsed]"
        fi
        if (( iteration > 120 )); then
            run_dialog timeout
            error_output 4 "Timeout reached waiting for $permission, exiting"
        fi
    done &
    /bin/sleep 0.5
    while true; do
        if get_full_disk_access_status; then
            break
        fi
        if ! (( showed_dialog )); then
            showed_dialog=1
            print_output "$permission required for $terminal_app_name, displaying dialog"
            print_output "Upon identifying the correct permissions, System Settings will quit and the script continue"
            run_dialog permissions
            case $? in
            0)
                print "button1: disable" >> $default_command_file
                print "button1text: Waiting" >> $default_command_file
                print "message: Waiting for $permission to be granted" >> $default_command_file
                print_output "Opening System Preferences"
                print_output "Please enable $terminal_app_name for $permission"
                /usr/bin/open $prefs_panel_path 2> /dev/null;;
            4)
                error_output 4 "Timeout reached waiting for $permission, exiting";;
            5)
                print_output "Permissions were granted without dialog interaction, continuing"
                break;;
            *)
                error_output $? "User cancelled process with GUI, exiting";;
            esac
        fi
        /bin/sleep 1
    done
    print "quit:" >> $default_command_file
    print_output "$terminal_app_name now has $permission, continuing"
    # Click Later button, and quit System Settings
    close_system_settings
    print "activate: " >> $default_command_file
}

# Establish the user account to backup
establish_user() {
    print_output "Waiting for user to make backup source selection(s)"
    run_dialog user_selection
    print_output "User selection made: $selected_user"
    if (( include_shared )); then
        print_output "Shared folder included: true"
    fi
}

# Create the backup target folder
create_backup_target() {
    datestamp=$(/bin/date +%Y-%m-%d)
    onedrive_folder="Library/Group Containers/UBF8T346G9.OneDriveStandaloneSuite"
    case $selected_user in
    all|shared)
        computer_name=$(/usr/sbin/scutil --get ComputerName)
        backup_folder="$script_folder/backup_${computer_name}_${datestamp}";;
    *)
        backup_folder="$script_folder/backup_${selected_user}_${datestamp}";;
    esac
    if [ -d "$backup_folder" ]; then
        print_output "Backup folder already exists, adding a timestamp to the folder name"
        backup_folder+="-$(/bin/date +%H.%M.%S)"
    fi

    print_output "Creating backup folder: $backup_folder"
    if ! /bin/mkdir -p $backup_folder; then
        progress_update unable_to_create
        error_output 7 "Unable to create backup folder, exiting"
    fi
    /usr/sbin/chown -R 99:99 $backup_folder
    if ! [ -w $backup_folder ]; then
        progress_update unable_to_write
        error_output 8 "Unable to write to backup folder, exiting"
    fi

    # Build rsync dry-run file list for progress tracking
    print_output "Building source file list …"
    files_to_copy_log="$backup_folder/file_list.log"
    error_log="$backup_folder/file_list_error.log"
    # Construct sources (mirrors final rsync)
    sources=()
    case $selected_user in
        all)
            for u in $users_from_folders; do
                sources+=("/Users/$u")
            done;;
        shared)
            sources+=("/Users/Shared");;
        *)
            sources+=("/Users/$selected_user")
            (( include_shared )) && sources+=("/Users/Shared");;
    esac
    sources+=("$app_support_folder")

    for exclude in $base_exclusions; do
        dry_excludes+=("--exclude" $exclude)
    done

    for pattern in $base_exclusions; do
        du_excludes+=("-I" $pattern)
    done

    # Run du to get rough size estimate (KB)
    du_space_req=0
    du_file_count=0
    for src in $sources; do
        if [[ -d $src ]]; then
            du_output=$(/usr/bin/du -ackx $du_excludes $src 2>/dev/null)
            size=$(/usr/bin/awk '/\ttotal/ {print $1}' <<< $du_output)
            count=$(/usr/bin/awk 'END {print NR-1}' <<< $du_output)
            (( du_space_req += size ))
            (( du_file_count += count ))
        fi
    done

    # Run rsync dry-run to get file list (path)
    dry_flags=(-axHn $dry_excludes --out-format="%f" --ignore-errors --stats)
    if ! $rsync_bin $dry_flags $sources $backup_folder > $files_to_copy_log 2> $error_log; then
        print_output "Warning: exact file listing failed, using rough size estimate …"
        file_count=$du_file_count
        space_req=$du_space_req
        unset files_to_copy_log
    fi

    # Free space (KB)
    space_free=$(/bin/df -k $script_folder | awk 'NR==2 {print $4}')
    space_free_string=$(kbToHumanReadable $space_free)

    # Get total number of files from rsync stats
    if [[ -f $files_to_copy_log ]]; then
        rsync_file_count=$(/usr/bin/grep 'Number of files:' $files_to_copy_log | /usr/bin/tr -cd '0-9')
        rsync_space_req_bytes=$(/usr/bin/grep 'Total file size:' $files_to_copy_log | /usr/bin/tr -cd '0-9')
        rsync_space_req=$(( rsync_space_req_bytes / 1024 ))  # to KB
    fi
    print_output "rsync_file_count: $rsync_file_count"
    print_output "rsync_space_req: $rsync_space_req"
    print_output "du_file_count: $du_file_count"
    print_output "du_space_req: $du_space_req"
    if (( rsync_space_req > 0 )); then
        space_req=$rsync_space_req
    else
        space_req=$du_space_req
    fi
    if (( rsync_file_count > 0 )); then
        file_count=$rsync_file_count
    else
        file_count=$du_file_count
    fi
    space_req_string=$(kbToHumanReadable $space_req)
    total_space_string="$space_req_string/$space_free_string required"
    total_space_percent=$(( space_req * 100 / (space_free==0?1:space_free) ))
    print_output "Total space required: $space_req_string"
    print_output "Space available: $space_free_string"
    print_output "Estimated backup size (in percent of available disk space): $total_space_percent%"

    # clean up file list and dry-run logs
    for log in $files_to_copy_log $error_log; do
        if [[ -f $log ]]; then
            /bin/rm -f $log
        fi
    done

    if (( space_free < space_req )); then
        return 1
    fi
}

# Display the ready to run message
ready_to_run() {
    if pgrep -q OneDrive; then
        print_output "OneDrive is currently running, but backing it up has proven problematic"
        print_output "OneDrive is therefore not included in the backup"
        print_output "Ensure that OneDrive has fully synced before proceeding as it will be terminated"
    fi
    print_output "Save any documents and close all applications but Terminal.app before continuing"
    run_dialog ready || return 1
}

# Display the progress of the rsync operation by monitoring the rsync progress log
get_progress_status() {
    local current_lines=0
    local files_done=0
    local processed_lines=0
    local last_update_epoch=0
    local last_file=""

    while kill -0 $rsync_pid 2>/dev/null; do
        local now=$(/bin/date +%s)
        # Read only new lines
        if [[ -f $progress_log ]]; then
            current_lines=$(( $(wc -l < $progress_log) ))
            if (( current_lines > processed_lines )); then
                # Read new segment
                while IFS= read -r line; do
                    [[ $line == *:* ]] && continue
                    last_file=$line
                    (( files_done++ ))
                done < <(/usr/bin/sed -n "$((processed_lines+1)),$current_lines p" $progress_log)
                processed_lines=$current_lines
            fi
        fi

        # Throttle to 4 Hz
        if (( now != last_update_epoch )); then
            last_update_epoch=$now
            (( files_done > file_count )) && files_done=$file_count
            local current_display="${last_file:-(starting …)}"
            if (( ${#current_display} > 40 )); then
                current_display="…${current_display: -40}"
            fi
            local msg="Processing: $files_done/$file_count files copied • $current_display"
            print -n "\r\033[K$msg"
            print "progresstext: $msg" >> $command_file
        fi
        /bin/sleep 0.1
    done

    # Final update
    if (( retry_count > 0 )); then
        local msg="[$USER] Backup complete after $retry_count retries: $files_done/${file_count} files copied"
    else
        local msg="[$USER] Backup complete: $files_done/${file_count} files copied"
    fi
    print -n "\r\033[K$msg\n"
    print "progresstext: $msg" >> $command_file
}

terminate_process() {
    process=$1
    break_counter=0
    print_output "Checking for and quitting $process processes"
    while /usr/bin/pgrep -q $process; do
        /usr/bin/osascript -e 'quit app "$process"' &> /dev/null
        /bin/sleep 15
        /usr/bin/pkill -9 $process &> /dev/null
        if [ $break_counter -gt 2 ]; then
            print "$process processes still running attempting to quit them for 30 seconds, exiting"
            return 1
        fi
        ((break_counter++))
    done
    /bin/sleep 1
}

run_backup() {
    backup_log="$backup_folder/backup_process.log"
    progress_log="$backup_folder/progress.log"
    : > "$progress_log"

    # Re-build sources (must mirror dry-run)
    sources=()
    case $selected_user in
        all)
            for u in $users_from_folders; do
                sources+=("/Users/$u")
            done;;
        shared)
            sources+=("/Users/Shared");;
        *)
            sources+=("/Users/$selected_user")
            (( include_shared )) && sources+=("/Users/Shared");;
    esac
    sources+=("$app_support_folder")

    # Ensure OneDrive is not running
    if (( retry_count > 0 )); then
        if ! terminate_process "OneDrive"; then
            error_output 7 "Unable to terminate OneDrive processes, exiting"
        fi
    fi

    # Build excludes
    excludes=()
    for exclude in $base_exclusions; do
        excludes+=("--exclude" $exclude)
    done

    # Base flags
    common_flags=("-axH" "--chmod=ugo=rwX" "--perms" "--ignore-errors" $excludes "--out-format=%f")

    if (( retry_count > 0 )); then
        print_output "Starting backup … (retry attempt $retry_count)"
    else
        print_output "Starting backup …"
    fi
    {
        print "Sources: $sources"
        print "Command: $rsync_bin $common_flags (sources...) $backup_folder/"
    } >> $backup_log

    $rsync_bin $common_flags $sources $backup_folder >> $progress_log 2>> $backup_log & rsync_pid=$!

    # Start progress monitor
    get_progress_status &
    local progress_pid=$!

    /usr/bin/caffeinate -imw $rsync_pid
    wait $rsync_pid
    local rc=$?

    # Ensure monitor exits
    wait $progress_pid 2>/dev/null

    if (( rc == 0 )); then
        # cleanup progress log since backup succeeded
        /bin/rm $progress_log
        print_output "Backup completed successfully ($retry_count retries)"
        return 0
    else
        # retrying failed backup
        print_output "Backup encountered errors, see ${backup_log:t} for details"
        max_retries=2
        if (( retry_count < max_retries )); then
            (( retry_count++ ))
            print_output "Retrying backup (attempt $retry_count of $max_retries)"
            print "progresstext: Retrying backup (attempt $retry_count/$max_retries)" >> $command_file
            print "listitem: index: 5, subtitle: Backup failed – retrying… ($retry_count/$max_retries)" >> $command_file
            sleep 2
            print_output "Progress indicators doesn't handle retries properly, expect erratic behavior in progress"
            if kill -0 $rsync_pid >/dev/null 2>&1; then
                kill -9 $rsync_pid >/dev/null 2>&1
            fi
            if kill -0 $progress_pid >/dev/null 2>&1; then
                kill -9 $progress_pid >/dev/null 2>&1
            fi
            run_backup
            return $?
        fi
        if (( retry_count == max_retries )); then
            print_output "Maximum retry attempts reached"
        fi
        print_output "Backup failed (exit code $rc) – see ${backup_log:t} for details"
        return 1
    fi
}

# Cleanup function
cleanup() {
    if [ -v command_file ]; then
        print "quit:" >> $command_file
    fi
    if (( EUID )); then
        print_output "Cleaning up $product_name run"
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
        print_output "Opening Self Service to the Jamf Connect migration policy"
        /usr/bin/open "jamfselfservice://content?entity=policy&id=949&action=view";;
    esac
}

# Show the erase assistant
show_erase_assistant() {
    print_output "Launching Erase Assistant"
    /usr/bin/open "/System/Library/CoreServices/Erase Assistant.app"
}

# Verify the backup
verify_backup() {
    print_output "Verifying backup"
    backup_size=$(/usr/bin/du -xck $backup_folder/*(DN) | awk '/\ttotal/ {print $1}')
    backup_size_string=$(kbToHumanReadable $backup_size)
    space_req_percent=$((backup_size / 10)) # 10% of backup size
    lower_bound=$((space_req - space_req_percent))
    upper_bound=$((space_req + space_req_percent))
    lower_bound_string=$(kbToHumanReadable $lower_bound)
    upper_bound_string=$(kbToHumanReadable $upper_bound)
    if ! ((backup_size >= lower_bound && backup_size <= upper_bound)); then
        print_output "Backup size: $backup_size_string"
        print_output "Expected size: $lower_bound_string to $upper_bound_string"
        backup_size_warning=1
    else
        print_output "Backup size: $backup_size_string"
    fi
}

# Cleanup the backup target folder
cleanup_backup_target() {
    print_output "Cleaning up backup target folder"
    if [ -d ${backup_folder?} ]; then
        /bin/rm -rf ${backup_folder}
    fi
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
            print_output "A new version ($new_version) of $product_name is available."
            run_dialog update
            case $? in
            0)
                print_output "Updating script to version $new_version"
                if ! /bin/mv $script_path "$script_path.bak"; then
                    return 2
                fi
                if ! /bin/mv $tmp_script_path $script_path; then
                    return 3
                fi
                if ! /bin/chmod +x $script_path; then
                    return 4
                fi
                print_output "Script updated successfully"
                $script_path
                exit 0;;
            2)
                print_output "Skipping $product_name update";;
            esac
        else
            print_output "You are running the latest version of the script"
        fi
    else
        return 1
    fi
}

# Main function
main() {
    set_variables $1
    if (( EUID )); then
        check_for_update
        update_return_code=$?
        case $update_return_code in
        1)  print_output "Unable to check for updates, continuing with the current version";;
        *)
            case $update_return_code in
            2)  error_output 2 "Unable to backup current script, exiting";;
            3)  error_output 3 "Unable to update script, exiting";;
            4)  error_output 4 "Unable to set permissions on updated script, exiting";;
            esac;;
        esac
    fi
    script_init
    if ! (( EUID )); then
        print "listitem: 0: success" >> $command_file
        print_output "Running as root, continuing"
    else
        elevate_script
        case $? in
        0)
            exit 0;;
        3)
            error_output 3 "Too many invalid selections, exiting";;
        4)
            error_output 4 "Timeout reached waiting for $permission, exiting";;
        5)
            error_output 5 "Too many user accounts found, please handle this computer manually";;
        2|6|10|137)
            error_output 6 "User cancelled process with GUI, exiting";;
        7)
            error_output 4 "Unable to create backup folder, exiting";;
        8)
            error_output 7 "Unable to write to backup folder, exiting";;
        9)
            error_output 8 "Not enough space on target, exiting";;
        11)
            error_output 2 "Unable to find dialog binary, exiting";;
        12)
            error_output 3 "No user folders found, exiting";;
        *)
            error_output 1 "Unhandled runtime error, exiting";;
        esac
    fi
    progress_update authenticate
    evaluate_full_disk_access
    progress_update permissions
    establish_user
    progress_update userselect
    if ! create_backup_target; then
        progress_update no_space
        run_dialog no_space
        print_output "Required: $space_req_string, Free: $space_free_string"
        error_output 9 "Not enough space on target disk to perform backup"
    fi
    progress_update ready
    ready_to_run
    progress_update going
    if ! run_backup; then
        error_output 1 "Backup process failed, exiting"
    fi
    verify_backup
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