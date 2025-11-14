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
# 2.0 - 2025-11-05
# - Switched backup engine to Time Machine instead of ditto/rsync for backups.
# - Improved the feedback during the backup process by parsing Time Machine status.
# - Enhanced logging and error handling throughout the script.
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
    zmodload zsh/pcre
    setopt EXTENDED_GLOB RE_MATCH_PCRE
    product_name="LiU Backup"
    version="2.0"
    script_name="${ZSH_ARGZERO:t}"
    script_path="${ZSH_ARGZERO:a}"
    script_folder="${ZSH_ARGZERO:h:a}"
    root_disk=$(/bin/df / | /usr/bin/awk '/\/dev/ {print $1}')
    script_disk=$(/bin/df $script_path | /usr/bin/awk '/\/dev/ {print $1}')
    [[ $script_disk =~ (/dev/)(disk[0-9]+)([a-z]+) ]] && script_disk_id=${match[2]}
    [[ $root_disk =~ (/dev/)(disk[0-9]+)([a-z]+) ]] && root_disk_id=${match[2]}
    if [[ $script_disk_id == $root_disk_id ]]; then
        print_output "$product_name is being run from an internal volume"
        error_output 16 "Move it to an external volume and try again"
    fi
    dialog_path="/usr/local/bin/dialog"
    _defaults="/usr/bin/defaults"
    _sudo="/usr/bin/sudo"
    _tmutil="/usr/bin/tmutil"
    library_folder="/Library"
    app_support_folder_path="$library_folder/Application Support"
    banner_path="$app_support_folder_path/LiU/Branding/liu_white_blue_1200x200_banner.png"
    alt_banner_path="color=#00cfb5"
    current_user=$(
        /usr/sbin/scutil <<< "show State:/Users/ConsoleUser" | /usr/bin/awk '/Name :/ && ! /loginwindow/ { print $3 }' )
    current_uid=$(/usr/bin/id -u $current_user 2> /dev/null)
    users_root="/Users"
    shared_user_path="$users_root/Shared"
    print -nf '\e[8;30;120t'
    if (( EUID )); then
        clear
        print_output "$product_name $version launching"
        tmp_dir=$(/usr/bin/mktemp -d "/tmp/$script_name.XXXXXX")
    else
        if ! [ -d ${1:-none} ] ; then
            error_output 2 "Don't run this script as $USER, exiting"
        fi
        tmp_dir=$1
        # get user data from /Users folder in the form data[username]=size_in_kb
        typeset -Ag user_data=()
        for user in ${(@f)$(print -l $users_root/^_*(^u:root:))}; do
            user_data[${user:t}]=0
        done
        # add Shared folder to the list if it exists, but only if it has files in it
        shared_folder_has_content=0
        shared_folder_size=0
        if [ -d $shared_user_path ]; then
            if (( $(print -l $shared_user_path/*(DN) | /usr/bin/wc -l) )); then
                shared_folder_has_content=1
            fi
        fi
        if (( ${#user_data} == 0 )); then
            error_output 12 "No user accounts found, exiting"
        elif (( ${#user_data} == 1 )); then
            print_output "${#user_data} user found"
        else
            print_output "${#user_data} users found"
        fi
    fi
    can_eacas=0
    case $(/usr/bin/arch) in
    i386)
        if system_profiler SPiBridgeDataType | /usr/bin/grep -q "Apple T2 Security"; then
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
    if ! /usr/bin/dsmemberutil checkmembership -U $current_user -G admin | /usr/bin/grep -q "user is a member of the group"; then
        run_dialog nonadmin
        error_output 1 "Script needs to be run from a local administrator account, exiting"
    fi
    terminal_app_name="Terminal"
    utilities_folder="/System/Applications/Utilities"
    terminal_app_path="$utilities_folder/$terminal_app_name.app"
    permission="Full Disk Access"
    fda_prefs_panel="x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    tm_panel="x-apple.systempreferences:com.apple.Time-Machine-Settings.extension"
    tm_preference_file="$library_folder/Preferences/com.apple.TimeMachine.plist"
}

# Prints a message to the terminal prefixed with the current user
print_output() {
    local timestamp=$(/bin/date -j +"%Y-%m-%d %H:%M:%S")
    print -- "[${timestamp}] [${USER:l}] $*"
}

# Prints an error message to the terminal and exits
error_output() {
    code=${?:=1}; shift
    local timestamp=$(/bin/date -j +"%Y-%m-%d %H:%M:%S")
    case $code in
    1)
        print_output "Unhandled runtime error, exiting";;
    *)
        print -- "[${timestamp}] [${USER:l}] $*"
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

    while (( i < $#units )); do
        # Use bc to compare value >= kb
        if (( $(print "$value >= $kb" | /usr/bin/bc -l) )); then
            value=$(print "scale=1; $value / $kb" | /usr/bin/bc -l)
            ((i++))
        else
            break
        fi
    done

    # Remove trailing .0
    value=${value%.0}
    printf "%s %s\n" "$value" "${units[i]}"
}

# Close System Preferences
close_system_settings() {
    killall "System Settings" >/dev/null 2>&1
    killall "System Preferences" >/dev/null 2>&1
}

# Run dialog with the provided arguments
run_dialog() {
    variant=$1; shift
    json_arguments='
        "titlefont": "name=KorolevLiU",
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
            "subtitle": "Investigating space requirements"}'
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
            "ontop": true,
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
            "ontop": true,
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
            "ontop": true,
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
            "ontop": true,
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
            "ontop": true,
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
        app_support_folder_size_human=$(kbToHumanReadable $app_support_folder_size)
        checkbox='{"label": "Application Support folder (~'${app_support_folder_size_human}')", "checked": true, "disabled": true}'
        user_list=()
        total_size=0
        for user in ${(ok)user_data}; do
            if [[ ${user_data[$user]} == 0 ]]; then
                user_size="no size data"
            else
                user_size="~$(kbToHumanReadable ${user_data[$user]})"
                total_size=$(( total_size + user_data[$user] ))
            fi
            user_list+="${user} ($user_size)"
        done
        if (( $#user_list > 1 )); then
            user_list+="---"
            user_list+="All users above (~$(kbToHumanReadable $total_size))"
        fi
        selection_values="${(j:,:)${(qqq@f)user_list}}"
        default=${user_list[1]}
        values='"values": ['$selection_values']'
        if (( shared_folder_has_content )); then
            shared_size_human=$(kbToHumanReadable $shared_folder_size)
            checkbox+=',{"label": "Include Shared folder (~'${shared_size_human}')", "checked": false}'
            json_arguments+='
                "checkbox": ['$checkbox'],
                "vieworder": "dropdown, checkbox",'
        fi
        selectitems='"title": "User", "required": true, '$values', "default": "'$default'"'
        json_arguments+='
            "ontop": true,
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
            "ontop": true,
            "width": "600",
            "height": "400",
            "bannerimage": "'$alt_banner_path'",
            "bannertitle": "Not enough space",
            "timer": 30,
            "button1text": "Abort",
            "icon": "SF=externaldrive.badge.xmark,palette=#ff6442,#00cfb5",
            "message": "'${message}'"';;
    add_destination_fail)
        message=("Failed to automatically add the Time Machine backup destination."
            "Please try to manually add this path through System Settings:<br><br>"
            "    $tm_destination_path<br><br>"
            "Once added, this dialog will close automatically.")
        json_arguments+='
            "ontop": true,
            "width": "700",
            "height": "400",
            "bannerimage": "'$alt_banner_path'",
            "bannertitle": "Failed to add destination",
            "timer": 120,
            "button1text": "Waiting …",
            "button1disabled": true,
            "button2text": "Cancel",
            "icon": "SF=externaldrive.badge.xmark,palette=#ff6442,#00cfb5",
            "message": "'${message}'"';;
    backup_failed)
        message=("The Time Machine backup process failed unexpectedly.<br>"
            "Check the logs for more information.")
        json_arguments+='
            "ontop": true,
            "width": "600",
            "height": "400",
            "bannerimage": "'$alt_banner_path'",
            "bannertitle": "Backup failed",
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
            "| Free | $space_free_string |<br><br>")
        message+=("We're all set to start the backup process.")
        if /usr/bin/pgrep -q OneDrive; then
            message+=(
                "<br><br>**Note**<br>OneDrive is currently running, but backing it up"
                "has proven problematic, and might **not be fully included** in the backup."
                "Ensure that OneDrive has *fully* synced **before** proceeding as it will be forcefully quit.")
            (( height += 200 ))
            warn=1
            timer=''
        fi
        if (( $(print "$total_space_percent > 90" | /usr/bin/bc -l) )); then
            warn=1
            timer=''
            print_output "Warning: backup will take up nearly all available disk space on target"
            print_output "After backup, less than $((100-total_space_percent))% will be available"
            message+=(
                "<br><br>**Warning**<br>Backup will take up nearly all available disk space on target."
                "After backup, less than $((100-total_space_percent))% will be available on the target disk.")
            (( height += 100 ))
        fi
        if (( warn )); then
            json_arguments+='
                "checkbox": [
                    {
                        "label": "I understand",
                        "enableButton1": true
                    }
                ],
                "button1disabled": true,'
        fi
        json_arguments+='
            '$timer'
            "ontop": true,
            "width": "600",
            "height": "'$height'",
            "bannerimage": "'$alt_banner_path'",
            "button1text": "Start",
            "button2text": "Cancel",
            "message": "'${message}'",
            "bannertitle": "Ready to backup",
            "icon": "SF=externaldrive.badge.timemachine,'$alt_banner_path'"';;
    next_steps)
        message=("The backup process has completed successfully.<br>")
        message+=("| Location | Time |<br>"
            "| :--- | :--- |<br>"
            "| $tm_destination_path | $tm_completion_time |<br><br>")
        message+=("At this point, you can choose to attempt a migration through Jamf, or reinstall macOS.")
        button1text="Attempt a migration"
        button2text="Quit $product_name"
        if (( can_eacas )); then
            message+=("<br><br>**Note**<br>To use the Erase Assistant you will have to authenticate again.")
            infobuttontext="Launch Erase Assistant"
            json_arguments+='
                "infobuttontext": "'$infobuttontext'",'
        else
            message+=(
                "<br><br>**Note**<br>The Erase Assistant is not available on this computer model."
                "Please use Recovery Mode to erase the computer.")
        fi
        json_arguments+='
            "ontop": true,
            "width": "750",
            "height": "'${next_steps_height:-550}'",
            "bannerimage": "'$alt_banner_path'",
            "bannertitle": "Backup completed",
            "button1text": "'$button1text'",
            "button2text": "'$button2text'",
            "icon": "SF=externaldrive.badge.checkmark,'$alt_banner_path'",
            "message": "'$message'"';;
    update)
        message=("<br>&nbsp;<br>Would you like to update?")
        json_arguments+='
            "ontop": true,
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
            "ontop": true,
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
        if (( dialog_exit_code == 0 )); then
            case $variant in
            authenticate)
                inputted_password=$(print -- $captured_input | /usr/bin/awk -F': ' 'tolower($0) ~ /password/ {print $NF}');;
            user_selection)
                selected_option=$(print -- $captured_input | /usr/bin/awk -F': ' '/SelectedOption/ {print $NF}' | /usr/bin/tr -d \")
                include_shared_response=$(print -- $captured_input | /usr/bin/awk -F': ' '/Include Shared folder/ {print $NF}' | /usr/bin/tr -d \")
                if [[ $include_shared_response == "true" ]]; then
                    include_shared=1
                else
                    include_shared=0
                fi
                case $selected_option in
                "All users above"*)
                    selected_user="all"
                    return;;
                esac
                selected_user=$(print $selected_option | /usr/bin/awk '{print $1}');;
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
        fi
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
    if ! $_sudo -Nnv &> /dev/null; then
        print_output "$product_name requires root privileges - showing GUI to authenticate"
        attempts=3
        while (( attempts )); do
            unset inputted_password
            run_dialog authenticate $attempts
            if /usr/bin/dscl . -authonly $current_user $inputted_password &> /dev/null; then
                # shellcheck disable=2296
                if print -n -- ${(q)inputted_password} | $_sudo -HSp "" true &> /dev/null; then
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
        $_sudo -H $script_path $tmp_dir
    elif (( password_correct )); then
        print_output "Elevated privileges granted, continuing"
        print $inputted_password | $_sudo -HSp "" $script_path $tmp_dir
    else
        print_output "Unable to authenticate user using GUI, trying osascript"
        /usr/bin/osascript -e 'do shell script "'$script_path $tmp_dir'" with administrator privileges'
    fi
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
        print "progresstext: Awaiting $terminal_app_name being granted $permission …" >> $command_file;;
    permissions)
        print "listitem: index: 2, status: success, statustext: Granted" >> $command_file
        print "listitem: index: 2, subtitle: $terminal_app_name granted $permission" >> $command_file
        print "listitem: index: 2, icon: SF=externaldrive.badge.checkmark color=#00bcec" >> $command_file
        print "progress: increment" >> $command_file
        print "progresstext: ✔︎ $terminal_app_name has been granted $permission" >> $command_file
        /bin/sleep 1
        print "listitem: index: 3, status: wait, statustext: Calculating" >> $command_file
        print "progresstext: Calculating user folder sizes …" >> $command_file;;
    usercalc)
        print "listitem: index: 3, status: success, statustext: Calculated" >> $command_file
        print "progress: increment" >> $command_file
        print "progresstext: ✔︎ User folder sizes calculated" >> $command_file
        /bin/sleep 1
        print "listitem: index: 3, status: wait, statustext: Waiting" >> $command_file
        print "progresstext: Awaiting backup source selection …" >> $command_file;;
    userselect)
        print "listitem: index: 3, status: success, statustext: Chosen" >> $command_file
        print "listitem: index: 3, subtitle: ${(qq)selected_user} selected" >> $command_file
        print "listitem: index: 3, icon: SF=person.crop.circle.badge.checkmark color=#00bcec" >> $command_file
        print "progress: increment" >> $command_file
        print "progresstext: ✔︎ Selection made ($selected_user)" >> $command_file
        /bin/sleep 1
        print "listitem: index: 4, status: wait, statustext: Investigating" >> $command_file
        print "progresstext: Investigating backup destination and space requirements …" >> $command_file;;
    ready)
        print "listitem: index: 4, status: success, statustext: Verified" >> $command_file
        print "listitem: index: 4, subtitle:${backup_folder:t}" >> $command_file
        print "progress: increment" >> $command_file
        print "progresstext: ✔︎ Backup destination: ${tm_destination_path} • $total_space_string" >> $command_file
        /bin/sleep 2
        print "listitem: index: 5, subtitle: ~$space_req_string to backup" >> $command_file
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
        print "progresstext: Backup in progress …" >> $command_file
        /bin/sleep 1;;
    next_steps)
        print "listitem: index: 5, status: success, statustext: Complete" >> $command_file
        print "listitem: index: 5, subtitle: Backup complete" >> $command_file
        print "progress: increment" >> $command_file
        print "progresstext: ✔︎ Backup complete" >> $command_file
        /bin/sleep 1
        print "listitem: index: 6, status: wait, statustext: Waiting" >> $command_file
        print "progresstext: Waiting for answer …" >> $command_file;;
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
        if $command $db_path $query 2> /dev/null | /usr/bin/grep -q $bundle_id; then
            return
        fi
        return 1
    }

    local iteration=0 showed_dialog=0
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
        if (( iteration > 3 )); then
            print "$iteration/120 seconds elapsed" > $tmp_dir/additional_msg
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
            show_animated_progress "Awaiting permission …" & local spinner_pid=$!
            run_dialog permissions
            case $? in
            0)
                print "progresstext: Waiting for $permission to be granted" >> $command_file
                print_output "Opening System Preferences"
                print -n "\r\033[K" && print_output "Please enable $terminal_app_name for $permission"
                /usr/bin/open $fda_prefs_panel 2> /dev/null;;
            4)
                if (( $spinner_pid )); then
                    kill $spinner_pid 2>/dev/null
                    print -n "\r\033[K"
                fi
                error_output 4 "Timeout reached waiting for $permission, exiting";;
            5)
                if (( $spinner_pid )); then
                    kill $spinner_pid 2>/dev/null
                    print -n "\r\033[K"
                fi
                print_output "Permissions were granted without dialog interaction, continuing"
                break;;
            *)
                if (( $spinner_pid )); then
                    kill $spinner_pid 2>/dev/null
                    print -n "\r\033[K"
                fi
                error_output $? "User cancelled process with GUI, exiting";;
            esac
        fi
        /bin/sleep 1
    done
    # Stop spinner
    kill $spinner_pid 2>/dev/null
    print -n "\r\033[K"
    # Finalize dialog
    print "quit:" >> $default_command_file
    print_output "$terminal_app_name now has $permission, continuing"
    # Click Later button, and quit System Settings
    close_system_settings
    print "activate: " >> $default_command_file
}

# Establish the user account to backup
establish_user() {
    # Start spinner (uses current shell pid; will be killed after computations)
    show_animated_progress "Calculating user folder sizes" & local spinner_pid=$!
    space_req=0
    for user in ${(k)user_data}; do
        user_path="$users_root/$user"
        du_output=$(/usr/bin/du -skx $user_path 2>/dev/null)
        if [[ $du_output =~ '(\d+)\s+(\S+)' ]]; then
            user_data[$user]=${match[1]}
        fi
        space_req=$(( space_req + user_data[$user] ))
    done
    if (( shared_folder_has_content )); then
        shared_folder_size=$(/usr/bin/du -skx $shared_user_path | /usr/bin/awk '{print $1}')
    fi
    app_support_folder_size=$(/usr/bin/du -skx $app_support_folder_path | /usr/bin/awk '{print $1}')
    space_req=$(( space_req + shared_folder_size + app_support_folder_size ))
    # Stop spinner
    kill $spinner_pid 2>/dev/null
    
    progress_update usercalc
    # Reset cursor
    printf "\r\033[K"
    print_output "User folder calculation complete"
    show_animated_progress "Awaiting backup source selection …" & spinner_pid=$!
    run_dialog user_selection
    # Stop spinner
    kill $spinner_pid 2>/dev/null
    printf "\r\033[K"
    print_output "User selection made: $selected_user"
    if (( include_shared )); then
        print_output "Shared folder included: true"
    fi
}

# Create the backup target folder
create_backup_target() {
    print_output "Preparing backup sources and destination …"
    # Define backup folder name and path
    datestamp=$(/bin/date -j "+%Y-%m-%d")
    case $selected_user in
    all|shared)
        computer_name=$(/usr/sbin/scutil --get ComputerName)
        backup_name="${computer_name}_${datestamp}"
        backup_folder="$script_folder/backup_$backup_name";;
    *)
        backup_name="${selected_user}_${datestamp}"
        backup_folder="$script_folder/backup_$backup_name";;
    esac
    if [ -d $backup_folder ]; then
        print_output "Backup folder already exists, adding a timestamp to the folder name"
        backup_folder+="-$(/bin/date -j "+%H.%M.%S")"
    fi
    tm_destination_path="/Volumes/$backup_name"

    # Create backup folder
    print_output "Creating backup folder: $backup_folder"
    if ! /bin/mkdir -p $backup_folder; then
        progress_update unable_to_create
        return 7
    fi
    /usr/sbin/chown -R 99:99 $backup_folder
    if ! [[ -w $backup_folder ]]; then
        progress_update unable_to_write
        return 8
    fi

    # Create Time Machine volume
    if /usr/sbin/diskutil info $tm_destination_path &> /dev/null; then
        print_output "Time Machine volume already exists, skipping creation"
    else
        print_output "Creating Time Machine volume: $tm_destination_path"
        if ! /usr/sbin/diskutil quiet apfs addVolume $script_disk_id APFS $backup_name &> /dev/null; then
            return 13
        fi
    fi

    # Add Time Machine destination
    if ! manage_tm destination set $tm_destination_path && tm_destination_set=1; then
        # Monitor for destination being added
        local iteration=0 showed_dialog=0
        while true; do
            # Check if destination is set
            if manage_tm destination get_id $tm_destination_path > /dev/null; then
                print "quit:" >> $default_command_file
                break
            fi
            /bin/sleep 1
            if ! /usr/bin/pgrep -i dialog > /dev/null; then
                return 1
            fi
            (( iteration++ ))
            if kill -0 $dialog_pid 2>/dev/null; then
                print "$iteration/120 seconds elapsed" > $tmp_dir/additional_msg
            fi
            if (( $iteration > 120 )); then
                run_dialog timeout
                error_output 4 "Time Machine destination not set after 2 minutes, exiting"
            fi
        done &
        /bin/sleep 0.5
        while true; do
            if manage_tm destination get_id $tm_destination_path > /dev/null; then
                break
            fi
            if ! (( showed_dialog )); then
                showed_dialog=1
                print_output "Failed to automatically set Time Machine destination to $tm_destination_path"
                print_output "Please try to set '$tm_destination_path' manually in Time Machine preferences"
                print_output "Opening Time Machine preferences"
                /usr/bin/open $tm_panel 2> /dev/null
                show_animated_progress "Awaiting manual Time Machine destination addition …" & local spinner_pid=$!
                print "button1: disable" >> $default_command_file
                print "button1text: Waiting" >> $default_command_file
                print "progresstext: Waiting for Time Machine destination to be set" >> $command_file
                run_dialog add_destination_fail
                case $? in
                4)
                    if (( spinner_pid )); then
                        kill $spinner_pid 2>/dev/null
                        print -n "\r\033[K"
                    fi
                    error_output 4 "Timeout reached waiting for Time Machine destination, exiting";;
                5)
                    if (( spinner_pid )); then
                        kill $spinner_pid 2>/dev/null
                        print -n "\r\033[K"
                    fi
                    print_output "Time Machine destination set, continuing"
                    break;;
                *)
                    if (( spinner_pid )); then
                        kill $spinner_pid 2>/dev/null
                        print -n "\r\033[K"
                    fi
                    error_output $? "User cancelled process with GUI, exiting";;
                esac
            fi
            /bin/sleep 1
        done
        # Stop spinner
        kill $spinner_pid 2>/dev/null
        print -n "\r\033[K"
        # Finalize dialog
        print "quit:" >> $default_command_file
        print_output "Time Machine destination now set to $tm_destination_path, continuing"
        tm_destination_set=1
        /bin/sleep 3
    fi

    # Show spinner while preparing sources and exclusions
    show_animated_progress "Preparing backup sources and destination …" & local spinner_pid=$!
    # Gather sources
    typeset -Ua sources=()
    case $selected_user in
    all)
        for u in ${(k)user_data}; do
            sources+=("$users_root/$u")
        done;;
    *)
        sources+=("$users_root/$selected_user");;
    esac
    (( include_shared )) && sources+=($shared_user_path)
    sources+=($app_support_folder_path)

    # Read existing exclusions
    manage_tm exclusions read

    # Build root exclusion list
    root_folder_contents=("${(@f)$(print -l /*(DN))}")
    # shellcheck disable=1036,1072,1073
    root_exclusions=("${(@f)$(print -l $root_folder_contents | /usr/bin/grep -Fxv -f =(print -l $sources))}")
    # print -l "Root exclusions:" "${(@)root_exclusions}"

    # Build user exclusion list
    user_folder_contents=("${(@f)$(print -l $users_root/*(DN))}")
    user_exclusions=("${(@f)$(print -l $user_folder_contents | /usr/bin/grep -Fxv -f =(print -l $sources))}")
    # print -l "User exclusions:" "${(@)user_exclusions}"

    # Build application support exclusion list
    app_support_folder_contents=("${(@f)$(print -l $library_folder/*(DN))}")
    app_support_exclusions=(
        "${(@f)$(print -l $app_support_folder_contents | /usr/bin/grep -Fxv -f =(print -l $sources))}")
    # print -l "Application Support exclusions:" "${(@)app_support_exclusions}"

    # Add all exclusions to Time Machine
    manage_tm exclusions set && tm_exclusions_set=1

    # Stop spinner
    kill $spinner_pid 2>/dev/null
    printf "\r\033[K"

    # Sources
    print_output "Backup sources:"
    for source in $sources; do
        print_output "• $source"
    done

    # Free space (KB)
    space_free=$(/bin/df -k $script_folder | /usr/bin/awk 'NR==2 {print $4}')
    space_free_string=$(kbToHumanReadable $space_free)

    # Output summary of space requirements
    space_req_string=$(kbToHumanReadable $space_req)
    total_space_string="$space_req_string/$space_free_string required"
    total_space_percent=$(printf '%.1f' "$(print "$space_req * 100 / ${space_free:-1}" | bc -l)")
    print_output "Total space required: $space_req_string"
    print_output "Space available: $space_free_string"
    print_output "Estimated backup size (in percent of available disk space): ~$total_space_percent %"

    if (( space_free < space_req )); then
        progress_update no_space
        print_output "Required: $space_req_string, Free: $space_free_string"
        run_dialog no_space
        return 9
    fi
}

# Display the ready to run message
ready_to_run() {
    if /usr/bin/pgrep -q OneDrive; then
        print_output "OneDrive is currently running, but backing it up has proven problematic"
        print_output "Ensure that OneDrive has fully synced before proceeding as it will be terminated"
    fi
    print_output "Save any documents and close all applications but Terminal.app before continuing"
    run_dialog ready || return 1
}

# Display terminal spinner while performing tasks
show_animated_progress() {
    local msg=$1
    local progress=(⣶ ⣧ ⣏ ⡟ ⠿ ⢻ ⣹ ⣼)
    local i=0
    local additional_msg=""
    if [[ -f $tmp_dir/additional_msg ]]; then
        /bin/rm -f $tmp_dir/additional_msg
    fi

    while true; do
        additional_msg=""
        if [[ -f $tmp_dir/additional_msg ]]; then
            additional_msg=$(/bin/cat $tmp_dir/additional_msg 2> /dev/null) || additional_msg=""
        fi
        if [[ -n $additional_msg ]]; then
            print -n "\r\033[K${progress[i % ${#progress[@]} + 1]} $msg ($additional_msg)"
        else
            print -n "\r\033[K${progress[i % ${#progress[@]} + 1]} $msg"
        fi
        # Throttle to 10 Hz
        /bin/sleep 0.1
        ((i++))
    done
}

# Terminate a specified process
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

# Extract value from plist
plist_extract() {
    if (( $# < 1 || $# > 2 )); then
        error_output 1 "plist_extract only accepts 1 or 2 arguments"
    fi
    plist_data=$1
    if (( $# > 1 )); then
        key=$2
        output=$(/usr/bin/plutil -extract $key raw - <<< $plist_data)
        if (( $? )); then
            return 1
        fi
    else
        output=$(/usr/bin/plutil -p - <<< $plist_data)
        if (( $? )); then
            return 1
        fi
    fi
    if [[ -z $(print $output | tr -d '{}[]') ]]; then
        output=0
    fi
    print $output
}

# Manage Time Machine settings
manage_tm() {
    # Manage Time Machine exclusions
    manage_tm_exclusions() {
        local sub_verb=$1
        case $sub_verb in
        read)
            path_exclusions_to_leave=()
            if ! tm_preference_file_output=$($_sudo $_defaults read $tm_preference_file 2>/dev/null); then
                error_output 1 "Unable to read Time Machine preferences"
            fi
            if [[ -z $tm_preference_file_output ]]; then
                return
            fi
            skip_paths_output=$($_sudo $_defaults read $tm_preference_file SkipPaths 2>/dev/null)
            for line in ${(f)skip_paths_output}; do
                [[ $line == "(" || $line == ")" ]] && continue
                if [[ $line =~ '"(.*)"' ]]; then
                    pre_defined_path=${match[1]}
                    path_exclusions_to_leave+=($pre_defined_path)
                fi
            done;;
        set)
            exclusions_to_remove=()
            for exclusion in $app_support_exclusions $user_exclusions; do
                for leave_exclusion in $path_exclusions_to_leave; do
                    if [[ $exclusion == $leave_exclusion ]]; then
                        continue 2
                    fi
                done
                $_tmutil addexclusion -p $exclusion &> /dev/null
                path_exclusions_to_remove+=($exclusion)
            done;;
        remove)
            for exclusion in $path_exclusions_to_remove; do
                $_tmutil removeexclusion -p $exclusion &> /dev/null
            done
            print "exclusions removed" > $tmp_dir/additional_msg
            if (( $#path_exclusions_to_leave )); then
                print "Leaving these path exclusions in place:" > $backup_folder/tm_exclusions_left.txt
                for exclusion in $path_exclusions_to_leave; do
                    print " • $exclusion" >> $backup_folder/tm_exclusions_left.txt
                done
            fi;;
        *)
            error_output 1 "manage_tm exclusions '$1' is not a valid sub-verb";;
        esac
    }

    # Manage Time Machine destinations
    manage_tm_destinations() {
        local sub_verb=$1
        shift
        case $sub_verb in
        get_id)
            local ids_length dest_path=$1 output dest_name
            tmutil_output=$($_tmutil destinationinfo -X)
            ids_length=$(plist_extract $tmutil_output "Destinations")
            if ! (( ids_length )); then
                return 1
            else
                for i in {0..$((ids_length-1))}; do
                    dest_name=$(plist_extract $tmutil_output "Destinations.$i.Name")
                    if [[ $dest_name == ${dest_path:t} ]]; then
                        output=$(plist_extract $tmutil_output "Destinations.$i.ID")
                        print $output
                        return
                    fi
                done
            fi
            return 2;;
        remove)
            local dest_path=$1 dest_id output
            dest_id=$(manage_tm_destinations get_id $dest_path)
            print "removing Time Machine destination $dest_path" > $tmp_dir/additional_msg
            output=$($_tmutil removedestination $dest_id 2>&1) || return $?;;
        set)
            local dest_path=$1 output
            print_output "Adding Time Machine destination $dest_path"
            output=$($_tmutil setdestination -a $dest_path 2>&1) || return $?;;
        *)
            error_output 1 "manage_tm destination '$sub_verb' is not a valid sub-verb";;
        esac
    }

    # Manage Time Machine state
    manage_tm_state() {
        local sub_verb=$1
        shift
        case $sub_verb in
        auto)
            arg_req $@
            local arg=$1 desired_state current_state tm_state
            shift
            case $arg in
            on|enable|1)
                desired_state=1;;
            off|disable|0)
                desired_state=0;;
            *)
                error_output 1 "manage_tm state auto requires 'on' or 'off' argument";;
            esac
            if (( desired_state )); then
                manage_tm_state enable
            else
                manage_tm_state disable
            fi;;
        disable)
            print_output "Disabling automatic Time Machine backups"
            if ! $_tmutil disable &> /dev/null; then
                return 1
            fi;;
        enable)
            print_output "Enabling automatic Time Machine backups"
            if ! $_tmutil enable &> /dev/null; then
                return 1
            fi;;
        start)
            arg_req $@
            local dest_path=$1 dest_id
            dest_id=$(manage_tm destination get_id $dest_path)
            print_output "Starting Time Machine backup"
            if ! $_tmutil startbackup -d $dest_id &> /dev/null; then
                return 1
            fi;;
        stop)
            if manage_tm status running; then
                print_output "No ongoing Time Machine backups to stop"
                return
            fi
            print_output "Stopping ongoing Time Machine backup"
            if ! $_tmutil stopbackup &> /dev/null; then
                return 1
            fi;;
        *)
            error_output 1 "manage_tm state '$sub_verb' is not a valid sub-verb";;
        esac
    }

    # Ensure that an argument is present
    arg_req() {
        if (( $# < 1 )); then
            error_output 1 "manage_tm ${verb} requires an argument"
        fi
    }

    [[ -v _tmutil ]] || _tmutil="/usr/bin/tmutil"
    typeset -g manage_tm_exit_code=0

    arg_req $@
    local verb=$1
    shift
    case $verb in
    status)
        local sub_verb=${1:-default}
        if (( $# > 1 )); then
            shift
        fi
        case $sub_verb in
        latest)
            arg_req $@
            local dest_path=$1 output indate_fmt="%Y-%m-%d-%H%M%S" outdate_fmt="+%Y-%m-%d %H:%M:%S" outtime_fmt="%H:%M:%S"
            local today=$(/bin/date -jIdate) output_iso_form
            print "checking for latest Time Machine backup" > $tmp_dir/additional_msg
            datetime_string=$($_tmutil latestbackup -d $dest_path -t) || return $?
            if [[ -z $datetime_string ]]; then
                return 1
            fi
            output_iso_form=$(/bin/date -jf $indate_fmt $datetime_string $outdate_fmt)
            case $output_iso_form in
            $today*)
                output=$(/bin/date -jf "%Y-%m-%d %H:%M:%S" $output_iso_form "+today at $outtime_fmt");;
            *)  
                output=$(/bin/date -jf "%Y-%m-%d %H:%M:%S" $output_iso_form $outdate_fmt);;
            esac
            print $output;;
        running)
            tm_status=$($_tmutil status -X 2>/dev/null) || return $?
            if [[ $(plist_extract $tm_status "Running" 2>/dev/null) != true ]]; then
                return 1
            fi
            return 0;;
        *)
            tm_status=$($_tmutil status -X 2>/dev/null) || return $?
            print $tm_status
            return 0;;
        esac;;
    destination)
        arg_req $@
        local sub_verb=$1
        shift
        manage_tm_destinations $sub_verb $@ || return $?;;
    exclusions)
        arg_req $@
        local sub_verb=$1
        shift
        manage_tm_exclusions $sub_verb $@ || return $?;;
    state)
        arg_req $@
        local sub_verb=$1
        shift
        manage_tm_state $sub_verb $@ || return $?;;
    *)
        error_output 1 "manage_tm '$verb' is not a valid verb";;
    esac
}

# Run the backup process with retries
run_backup() {
    # Ensure OneDrive is not running
    if ! terminate_process "OneDrive"; then
        error_output 7 "Unable to terminate OneDrive processes, exiting"
    fi

    # Caffeinate during backup
    /usr/bin/caffeinate -dims & local caffeinate_pid=$!
    # Stop and pause automatic Time Machine backups (if any)
    manage_tm state auto off
    if ! manage_tm state stop; then
        error_output 1 "Failed to stop Time Machine backups"
    fi

    # Open Time Machine preferences to view backup progress
    if ! (( opened_tm_prefs )); then
        print_output "Opening Time Machine preferences to monitor backup progress"
        /usr/bin/open $tm_panel &> /dev/null
    fi

    # Monitor backup progress
    progress_update going

    # Start non-blocking so we can poll status
    if ! manage_tm state start $tm_destination_path; then
        print_output "Time Machine backup failed"
        kill $caffeinate_pid 2>/dev/null
        return 1
    fi

    # Terminal spinner while processing
    show_animated_progress "Running Time Machine backup …" & local spinner_pid=$!
    
    # Wait for a few seconds to allow Time Machine to initialize
    /bin/sleep 3

    local last_phase=""
    local last_percent_display=""
    local poll_interval=0.25
    typeset -g additional_msg=""

    while true; do
        tm_status=$(manage_tm status)
        running_flag=$(plist_extract $tm_status "Running" 2>/dev/null)
        # Treat any true Running as active (ignore isChoosingDestination after start)
        if [[ $running_flag != true ]]; then
            break
        fi
        phase=$(plist_extract $tm_status "BackupPhase" 2>/dev/null)


        time_remaining=$(plist_extract $tm_status "Progress.TimeRemaining" 2>/dev/null) || time_remaining=-1
        if [[ -n $time_remaining && $time_remaining != "-1" ]]; then
            # Round float to nearest second
            time_remaining_secs=$(printf '%.0f' "$time_remaining")
            local days=$(( time_remaining_secs / 86400 ))
            local rem=$(( time_remaining_secs % 86400 ))
            local hours=$(( rem / 3600 ))
            local mins=$(( (rem % 3600) / 60 ))
            local secs=$(( rem % 60 ))
            if (( days > 0 )); then
                time_remaining_display=$(printf '~%dd %02dh%02dm remaining' $days $hours $mins)
            elif (( hours > 0 )); then
                time_remaining_display=$(printf '~%02dh%02dm remaining' $hours $mins)
            else
                time_remaining_display=$(printf '~%02dm remaining' $mins)
            fi
        else
            time_remaining_display="(calculating…)"
        fi
        raw_percent=$(plist_extract $tm_status "Progress.Percent" 2>/dev/null) || raw_percent=0
        [[ -z $raw_percent || $raw_percent == "-1" ]] && raw_percent=0
        fraction=$(plist_extract $tm_status "FractionOfProgressBar" 2>/dev/null) || fraction=0
        [[ -z $fraction ]] && fraction=0
        # Compute adjusted percent:
        # Treat fraction as the share of the total progress bar that this phase contributes.
        # So overall progress contributed by current phase = raw_percent * fraction.
        if (( $(print "$fraction <= 0" | /usr/bin/bc -l) )); then
            adjusted_percent=$raw_percent
        else
            adjusted_percent=$(print "scale=6; $raw_percent * $fraction * 100" | /usr/bin/bc -l)
        fi

        # Guard against starting state (both zero -> keep 0 not 100)
        if (( $(print "$raw_percent == 0" | /usr/bin/bc -l) )) && (( $(print "$fraction == 0" | /usr/bin/bc -l) )); then
            adjusted_percent=0
        fi
        # Clamp
        if (( $(print "$adjusted_percent > 100" | /usr/bin/bc -l) )); then
            adjusted_percent=100
        elif (( $(print "$adjusted_percent < 0" | /usr/bin/bc -l) )); then
            adjusted_percent=0
        fi
        LANG="en_US.UTF-8" percent_display=$(printf '%.1f' $adjusted_percent)
        files_processed=$(plist_extract $tm_status "Progress.files" 2>/dev/null)
        total_files=$(plist_extract $tm_status "Progress.totalFiles" 2>/dev/null)

        [[ -z $phase ]] && phase="Initializing"

        if [[ $phase != $last_phase || $adjusted_percent != $last_adjusted_percent || $files_processed != $last_files_processed ]]; then
            output="Backup in progress …"
            term_output="overall progress:"
            if [[ -n $time_remaining_display ]]; then
                output+=" $time_remaining_display"
                term_output+=" $time_remaining_display"
            fi
            if [[ -n $percent_display ]]; then
                output+=" ($percent_display %)"
                term_output+=" ($percent_display %)"
            fi
            if [[ -n $phase ]]; then
                output+=" • $phase"
                term_output+=" • $phase"
            fi
            if [[ -n $files_string ]]; then
                term_output+=" • $files_processed / $total_files files"
            fi
            print "$term_output" > $tmp_dir/additional_msg
            print "progresstext: $output" >> $command_file
            last_phase=$phase
            last_adjusted_percent=$adjusted_percent
            last_percent_display=$percent_display
            last_files_processed=$files_processed
        fi

        /bin/sleep $poll_interval
    done

    # Stop spinner
    kill $spinner_pid 2>/dev/null
    kill $caffeinate_pid 2>/dev/null
    /bin/sleep 0.2
    /bin/rm -f $backup_folder/additional_msg
    printf "\r\033[K"

    # Check backup result
    tm_completion_time=$(manage_tm status latest $tm_destination_path)
    completion_code=$?
    if (( completion_code )); then
        run_dialog backup_failed
        return 15
    fi
    print_output "Time Machine backup completed successfully"
    print "progresstext: ✔︎ Time Machine backup complete" >> $command_file
    print "listitem: index: 5, subtitle: Backup complete" >> $command_file

    /bin/sleep 5
    close_system_settings

    print_output "Latest backup time: $tm_completion_time"
    print_output "Backup location: $tm_destination_path"
    
    print_output "Restoring Time Machine settings …"
    # Remove Time Machine destination and exclusions
    manage_tm destination remove $tm_destination_path
    manage_tm exclusions remove

    # Restore automatic Time Machine backup state
    manage_tm state auto on
    tm_restored=1

    # Create application list
    print_output "Making a list of installed applications"
    /bin/sleep 1
    local app_type="kMDItemContentTypeTree=com.apple.application-bundle"
    /usr/bin/mdfind $app_type -onlyin /Applications/ > "$backup_folder/application_list.txt"
    /bin/sleep 1
    print_output "Installed application list created at $backup_folder/application_list.txt"
    print_output "Backup process complete"
}

# Cleanup function
cleanup() {
    if (( tm_destination_set && ! completion_code )); then
        manage_tm destination remove $tm_destination_path
    fi
    if (( tm_exclusions_set )); then
        manage_tm exclusions remove
    fi
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

# Revoke Full Disk Access from Terminal.app
revoke_full_disk_access() {
    print_output "Revoking Full Disk Access from Terminal.app"
    if ! /usr/bin/tccutil reset SystemPolicyAllFiles com.apple.Terminal &> /dev/null; then
        print_output "Failed to revoke Full Disk Access from Terminal.app, please do this manually in System Settings"
    fi
    /bin/sleep 2
}

# Ask the user if they want to migrate
next_steps() {
    # Revoke Full Disk Access from Terminal.app
    revoke_full_disk_access
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
        new_version=$(/usr/bin/awk -F = '/^    version/ {print $NF}' $tmp_script_path | /usr/bin/tr -d '"')
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
            5)  error_output 5 "Unable to set permissions on updated script, exiting";;
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
        2|6|10|137)
            error_output 6 "User cancelled process with GUI, exiting";;
        7)
            error_output 7 "Unable to create backup folder, exiting";;
        8)
            error_output 8 "Unable to write to backup folder, exiting";;
        9)
            error_output 9 "Not enough space on target, exiting";;
        11)
            error_output 11 "Unable to find dialog binary, exiting";;
        12)
            error_output 12 "No user folders found, exiting";;
        13)
            error_output 13 "Unable to create Time Machine volume, exiting";;
        14)
            error_output 14 "Time Machine backup didn't complete, exiting";;
        *)
            error_output 1 "Unhandled runtime error, exiting";;
        esac
    fi
    progress_update authenticate
    evaluate_full_disk_access
    progress_update permissions
    establish_user
    progress_update userselect
    create_backup_target
    exit_code=$?
    case $exit_code in
    7)
        error_output 7 "Unable to create backup folder, exiting";;
    8)
        error_output 8 "Unable to write to backup folder, exiting";;
    9)
        error_output 9 "Not enough space on target disk to perform backup";;
    13)
        error_output 13 "Unable to create Time Machine volume, exiting";;
    14)
        error_output 14 "Unable to set Time Machine destination, exiting";;
    16)
        error_output 16 "Script is being run on an internal disk, aborting"
    esac
    progress_update ready
    ready_to_run
    progress_update going
    run_backup
    exit_code=$?
    case $exit_code in
    15)
        error_output 15 "Time Machine backup didn't complete, exiting";;
    esac
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