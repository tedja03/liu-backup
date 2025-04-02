#!/usr/bin/env zsh -x

# This script will list all files and folders larger than 1GB in size
# for a specified user's home folder and the /Library/Application Support
# folder. If no user is specified, the script will prompt for a username.
# The script will output the results to the terminal and save them to a log file.

# Author: Ted Jangius
# Version: 1.0
# Date: 2025-03-25
# Author: 

setopt extended_glob

setup_colors() {
    declare -g c='\033[0;36m' g='\033[0;32m' m='\033[0;35m' n='\033[0;39m' \
    r='\033[0;31m' y='\033[0;33m' i='\033[3m' f='\033[2m' res='\033[0m'
}

bytesToHumanReadable() {
    local i=1
    local bytes=$1
    local kb=1000.0
    local units=(KB MB GB TB PB EB ZB YB)
    while ((bytes > kb)); do
        bytes=$((bytes / kb))
        ((i++))
    done
    print "${bytes:0:4}${units[i]}"
}

calculate_depth() {
    local input_path=$1
    local depth=$(print $input_path | awk -F'/' '{print NF-1}')
    print $depth
}

parse_args() {
    # Define options
    zparseopts -D -E -K -M -- \
        p:=folder_path -path=folder_path \
        u:=username -user=username \
        h=flag_help -help=flag_help || return 1
    
    # Handle help option
    if (( ${#flag_help} )); then
        usage 0
    fi

    # Handle path option (-p/--path)
    if (( ${#folder_path} )); then
        for arg value in $folder_path; do
            folder_path=$value
        done
        if [[ -z $folder_path ]]; then
            print "${r}Error$n: The -p parameter (path) is required."
            usage 3
        fi
        if [[ -d $folder_path ]]; then
            list_large_files_and_folders $folder_path
            exit 0
        else
            print "${y}Warn$n: The specified path ($y$folder_path$n) does not exist."
            usage 1
        fi
    fi
    # Handle username option (-u/--username)
    if (( ${#username} )); then
        for arg value in $username; do
            selected_user=$value
        done
        if [[ -z $selected_user ]]; then
            print "${r}Error$n: The -u parameter (username) is required."
            usage 2
        fi
    else
        # Prompt user to select from a list if no arguments are provided
        print "Make a selection from the list below:"
        users_from_folders=(${(@f)$(print -l /Users/^_*(^u:root:)):t})
        select user in $users_from_folders "exit script"; do
            case $user in
            "exit script")
                usage 0;;
            "")
                usage 3 $REPLY;;
            *)
                selected_user=$user
                break;;
            esac
        done
    fi

    if [[ ! -d "/Users/$selected_user" ]]; then
        print "${y}Warn$n: The specified user ($y$selected_user$n) does not exist."
        usage 2
    fi


    if [[ -z $selected_user ]]; then
        usage 2
    fi
}

get_active_levels() {
    local iter_path=$1
    local indent_level=$(( $(calculate_depth ${iter_path}) - input_level ))
    if (( indent_level < 1 )); then
        return
    fi
    for index in {1..$indent_level}; do
        parent_count=${subitem_count[${iter_path:h}]:-0}
        current_count=${subitem_count[$iter_path]:-0}
        if (( parent_count >= 1 )); then
            active_levels=(1 $active_levels)
        else
            active_levels=(0 $active_levels)
        fi
        iter_path=${iter_path:h}
    done
}

list_large_files_and_folders() {
    local input_path=$1
    local no_files_string="no files larger than 1GB here"

    if [ ! -d $input_path ]; then
        print "The specified path is not a directory."
        return 1
    fi

    unset -v items_array
    declare -A directory_array files_array items_array subitem_count
    while read -r item_size item_path; do
        if [ -f $item_path ]; then
            files_array[$item_path]=$item_size
        elif [ -d $item_path ]; then
            directory_array[$item_path]=$item_size
        fi
        items_array[$item_path]=$item_size
    done < <(/usr/bin/du -xack $input_path | awk -F\t '$1 > 1000*1000 {print $1, "\t", $2}')

    total_size=$(( items_array[total] + total_size ))
    unset "items_array[total]"

    for item in "${(@k)items_array}"; do
        parent_path="${item:h}"
        ((subitem_count[$parent_path]++))
    done

    sorted_keys=(${(@on)${(k)items_array}})
    input_level=$(calculate_depth $input_path)
    if (( ${#sorted_keys} < 1 )); then
        input_path_size=$(/usr/bin/du -xck $input_path | awk '/\ttotal/ {print $1}')
        input_path_size_human=$(bytesToHumanReadable $input_path_size)
        total_size=$(( input_path_size + total_size ))
        print "$f$c$input_path_size_human\t$m$input_path$n"
        print "\t$c$f$i($no_files_string)$n"
        return 1
    fi
    # print -l sorted_keys: $sorted_keys
    for item_path in $sorted_keys; do
        file_in_path=0
        space_array=()
        active_levels=()
        indent_level=$(calculate_depth $item_path)
        parent_path=${item_path:h}
        parent_count=${subitem_count[$parent_path]:-0}
        current_count=${subitem_count[$item_path]:-0}
        ((subitem_count[$parent_path]--))

        get_active_levels $item_path
        is_descendant=0
        if [[ $item_path == $previous_path* ]]; then
            is_descendant=1
        fi
        if [[ $item_path == $input_path ]]; then
            active_levels=()
        else
            for index in {1..${#active_levels}}; do
                ! (( index )) && continue
                if (( active_levels[$index] )); then
                    space_array[$index]=(" │")
                    if (( index == ${#active_levels})); then
                        space_array[$index]=(" ├─")
                    elif (( index == next_indent_level )); then
                        space_array[$index]=(" ├─")
                    fi
                else
                    if (( index == ${#active_levels} )); then
                        space_array[$index]=(" └─")
                    else
                        space_array[$index]=("  ")
                    fi
                fi
            done
        fi
        file_string=${item_path:t}
        current_size=$items_array[$item_path]
        current_size_human=$(bytesToHumanReadable $items_array[$item_path])
        if [ -d $item_path ]; then
            case $current_size_human in
            $previous_size_human)
                current_size=0;;
            esac
            if (( indent_level == input_level )); then
                color="$m"
                file_string=${item_path:a}
            else
                color="$m$f"
            fi
        else
            color="$g"
            file_in_path=1
        fi
        if (( current_size )); then
            if ! (( ${#active_levels} )); then
                print "$c$current_size_human$n\t${(j::)space_array}$color$file_string$n"
            else
                print "$c$f$current_size_human$n\t${(j::)space_array}$color$file_string$n"
            fi
        else
            print "\t${(j::)space_array}$color$file_string$n"
        fi
        previous_level=$indent_level
        previous_path=$item_path
        previous_size_human=$current_size_human
        previous_space_array=(${space_array#*└─})
        current_index=${sorted_keys[(Ie)$item_path]}
        next_index=$((current_index + 1))
        next_item=${sorted_keys[$next_index]}
        next_indent_level=$(calculate_depth ${sorted_keys[$next_index]})
        if (( indent_level > next_indent_level )); then
            subfiles_array=(${(k)files_array:#$next_item/*})
            if (( ${#subfiles_array} < 1 && ! file_in_path )); then
                print "\t${(j::)previous_space_array}   $c$f$i($no_files_string)$n"
            fi
        fi
    done
}

usage() {
    local exit_code=$1 info=$2
    case $exit_code in
    1) print "${r}Error$n\tthis script requires root permissions";;
    2) print "${r}Error$n\tunable to parse username; '$r$selected_user$n'";;
    3) print "${r}Error$n\tnot a valid selection; '$r$info$n'";;
    4) print "${r}Error$n\tuser is not a member of the admin group";;
    5) print "${r}Error$n\tunable to authenticate as $USER";;
    esac
    print "${y}Usage$res\t${ZSH_ARGZERO:t} [username]"
    print "\t$f$i(username is optional - the script will"
    print "\tprompt for a username if not provided)"
    exit $exit_code
}

main() {
    setup_colors
    log_file="${ZSH_ARGZERO:a:h}/${ZSH_ARGZERO:r:t}.log"
    /bin/rm -f $log_file
    if (( EUID )); then
        clear
        # check if current user is part of admin group
        if ! /usr/bin/dscl . -read /Groups/admin GroupMembership | /usr/bin/grep -q $USER; then
            usage 4
        fi
        # write out script output to file and stdout, stripping ANSI escape sequences and replacing tabs with 8 spaces for the log file
        if ! /usr/bin/sudo -vn 2> /dev/null; then
            print "Type the password for $y$USER$res to authenticate"
        fi
        # sudo session is valid
        /usr/bin/sudo $ZSH_ARGZERO $@
        usage $?
    fi
    parse_args $@
    case $? in
        1) usage 1;;
        2) usage 2;;
    esac
    user_home="/Users/$selected_user"
    app_support_folder="/Library/Application Support"
    datetime=$(date +%Y-%m-%d\ at\ %H:%M:%S)
    computer_name=$(/usr/sbin/scutil --get ComputerName)
    sep="$res──────  ──── ─── ── ─ "
    -
    {
        print "Calculating total size of:"
        print "  - $m$user_home$n"
        print "  - $m$app_support_folder$n"
        print "  $i${f}if file or folder ${c}size$res$i$f doesn't change, its size is omitted on the"
        print "  next row, and only files or folders larger than 1GB are listed"
        print ""
        print "  legend:$g files $res$f|$m root folders $res$f&$m$f subfolders $res"
        print "$sep"
        print "${c}Size$n\t${m}Path                            $res${f}Computer name: $y$computer_name$res"
        print "$sep"
        list_large_files_and_folders $user_home
        print "$sep"
        list_large_files_and_folders $app_support_folder
        print "$sep"
        print "$c$(bytesToHumanReadable $total_size)\tEstimated total size$res"
        print "$sep"
        print "Output generated on $datetime"
    } 2>&1 | /usr/bin/tee >(
        sed -e 's/\x1b\[[0-9;]*m//g' -e 's/^\t/        /g' -e 's/B\t/B  /g' -e 's/e\t/e    /g' > $log_file)
    print "Output saved to $log_file"
    /bin/chmod 777 $log_file
    print "${f}Press any key to exit …"
    read -sk1
}

main $@