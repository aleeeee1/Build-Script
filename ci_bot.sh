#!/bin/bash

# Load telegram vars from .env
source $(dirname $0)/.env

# Build Configuration. Required variables to compile the ROM.
CONFIG_LUNCH="aosp_laurel_sprout-bp1a-userdebug"
CONFIG_OFFICIAL_FLAG=""
CONFIG_TARGET="bacon"

# Turning off server after build or no
POWEROFF=false

# Script Constants. Required variables throughout the script.
YELLOW=$(tput setaf 3)
BOLD=$(tput bold)
RESET=$(tput sgr0)
BOLD_GREEN=${BOLD}$(tput setaf 2)
OFFICIAL="0"
ROOT_DIRECTORY="$(pwd)"

# Post Constants. Required variables for posting purposes.
DEVICE="$(sed -e "s/^[^_]*_//" -e "s/-.*//" <<<"$CONFIG_LUNCH")"
ROM_NAME="$(sed "s#.*/##" <<<"$(pwd)")"
OUT="$(pwd)/out/target/product/$DEVICE"
STICKER_URL="https://raw.githubusercontent.com/Weebo354342432/reimagined-enigma/main/update.webp"

# CLI parameters. Fetch whatever input the user has provided.
while [[ $# -gt 0 ]]; do
    case $1 in
    -s | --sync)
        SYNC="1"
        ;;
    -c | --clean)
        CLEAN="1"
        ;;
    -o | --official)
        if [ -n "$CONFIG_OFFICIAL_FLAG" ]; then
            OFFICIAL="1"
        else
            echo -e "$RED\nERROR: Please specify the flag to export for official build in the configuration!!$RESET\n"
            exit 1
        fi
        ;;
    -h | --help)
        echo -e "\nNote: • You should specify all the mandatory variables in the script!
      • Just run "./$0" for normal build
Usage: ./build_rom.sh [OPTION]
Example:
    ./$(basename $0) -s -c or ./$(basename $0) --sync --clean

Mandatory options:
    No option is mandatory!, just simply run the script without passing any parameter.

Options:
    -s, --sync            Sync sources before building.
    -c, --clean           Clean build directory before compilation.
    -o, --official        Build the official variant during compilation.\n"
        exit 1
        ;;
    *)
        echo -e "$RED\nUnknown parameter(s) passed: $1$RESET\n"
        exit 1
        ;;
    esac
    shift
done

# Configuration Checking. Exit the script if required variables aren"t set.
if [[ $CONFIG_LUNCH == "" ]] || [[ $CONFIG_TARGET == "" ]]; then
    echo -e "$RED\nERROR: Please specify all of the mandatory variables!! Exiting now...$RESET\n"
    exit 1
fi

# Telegram Environment. Declare all of the related constants and functions.
export BOT_MESSAGE_URL="https://api.telegram.org/bot$CONFIG_BOT_TOKEN/sendMessage"
export BOT_EDIT_MESSAGE_URL="https://api.telegram.org/bot$CONFIG_BOT_TOKEN/editMessageText"
export BOT_FILE_URL="https://api.telegram.org/bot$CONFIG_BOT_TOKEN/sendDocument"
export BOT_STICKER_URL="https://api.telegram.org/bot$CONFIG_BOT_TOKEN/sendSticker"
export BOT_PIN_URL="https://api.telegram.org/bot$CONFIG_BOT_TOKEN/pinChatMessage"

send_message() {
    local RESPONSE=$(curl -s "$BOT_MESSAGE_URL" -d chat_id="$2" \
        -d "parse_mode=html" \
        -d "disable_web_page_preview=true" \
        -d text="$1")
    local MESSAGE_ID=$(echo "$RESPONSE" | grep -o '"message_id":[0-9]*' | cut -d':' -f2)
    echo "$MESSAGE_ID"
}

edit_message() {
    curl -s "$BOT_EDIT_MESSAGE_URL" -d chat_id="$2" \
        -d "parse_mode=html" \
        -d "message_id=$3" \
        -d text="$1" > /dev/null
}

send_file() {
    curl -s --progress-bar -F document=@"$1" "$BOT_FILE_URL" \
        -F chat_id="$2" \
        -F "disable_web_page_preview=true" \
        -F "parse_mode=html" > /dev/null
}

send_sticker() {
    curl -sL "$1" -o "$ROOT_DIRECTORY/sticker.webp" > /dev/null

    local STICKER_FILE="$ROOT_DIRECTORY/sticker.webp"

    curl -s "$BOT_STICKER_URL" -F sticker=@"$STICKER_FILE" \
        -F chat_id="$2" \
        -F "is_animated=false" \
        -F "is_video=false" > /dev/null
}

send_message_to_error_chat() {
    local response=$(curl -s -X POST "$BOT_MESSAGE_URL" -d chat_id="$CONFIG_ERROR_CHATID" \
        -d "parse_mode=html" \
        -d "disable_web_page_preview=true" \
        -d text="$1")
    local MESSAGE_ID=$(echo "$RESPONSE" | grep -o '"message_id":[0-9]*' | cut -d':' -f2)
    echo "$MESSAGE_ID"
}

send_file_to_error_chat() {
    curl -s --progress-bar -F document=@"$1" "$BOT_FILE_URL" \
        -F chat_id="$CONFIG_ERROR_CHATID" \
        -F "disable_web_page_preview=true" \
        -F "parse_mode=html" > /dev/null
}

fetch_progress() {
    local PROGRESS=$(
        sed -n '/ ninja/,$p' "$ROOT_DIRECTORY/build.log" |
            grep -Po '\d+% \d+/\d+' |
            tail -n1 |
            sed -e 's/ / (/; s/$/)/'
    )

    if [ -z "$PROGRESS" ]; then
        echo "Initializing the build system..."
    else
        echo "$PROGRESS"
    fi
}

generate_ota_json() {
    local file_path="$1"
    local filename="$(basename "$file_path")"
    local product_out="$(dirname "$file_path")"
    local target_device="$(basename "$product_out")"

    local buildprop="$product_out/system/build.prop"
    local output="$product_out/$target_device.json"

    # Cleanup old output file
    if [ -f "$output" ]; then
        rm "$output"
    fi

    echo "Generating JSON file data for OTA support for device: $target_device"

    # Extract datetime from build.prop
    local datetime
    datetime=$(grep "ro.build.date.utc" "$buildprop" | cut -d'=' -f2)

    # SHA256 ID
    local id
    id=$(sha256sum "$file_path" | cut -d' ' -f1)

    # File size
    local size
    size=$(stat -c "%s" "$file_path")

    # Version parsing
    local version
    version=$(echo "$filename" | cut -d'-' -f2)

    # Output JSON
    cat <<EOF > "$output"
{
  "response": [
    {
      "datetime": "$datetime",
      "filename": "$filename",
      "id": "$id",
      "size": $size,
      "url": "",
      "version": "$version"
    }
  ]
}
EOF

    echo "JSON generated at: $output"
    cat "$output"
}

# Cleanup Files. Nuke all of the files from previous runs.
if [ -f "out/error.log" ]; then
    rm -f "out/error.log"
fi

if [ -f "out/.lock" ]; then
    rm -f "out/.lock"
fi

if [ -f "$ROOT_DIRECTORY/build.log" ]; then
    rm -f "$ROOT_DIRECTORY/build.log"
fi

# Jobs Configuration. Determine the number of cores to be used.
CORE_COUNT=$(nproc --all)
CONFIG_SYNC_JOBS="$([ "$CORE_COUNT" -gt 8 ] && echo "12" || echo "$CORE_COUNT")"
CONFIG_COMPILE_JOBS="$CORE_COUNT"

# Execute Parameters. Do the work if specified.
if [[ -n $SYNC ]]; then
    # Send a notification that the syncing process has started.

    sync_start_message="🟡 | <i>Syncing sources!!</i>

<b>• ROM:</b> <code>$ROM_NAME</code>
<b>• DEVICE:</b> <code>$DEVICE</code>
<b>• JOBS:</b> <code>$CONFIG_SYNC_JOBS Cores</code>
<b>• DIRECTORY:</b> <code>$(pwd)</code>"

    sync_message_id=$(send_message "$sync_start_message" "$CONFIG_CHATID")

    SYNC_START=$(TZ=Asia/Kolkata date +"%s")

    echo -e "$BOLD_GREEN\nStarting to sync sources now...$RESET\n"
    if ! repo sync -c --jobs-network=$CONFIG_SYNC_JOBS -j$CONFIG_SYNC_JOBS --jobs-checkout=$CONFIG_SYNC_JOBS --optimized-fetch --prune --force-sync --no-clone-bundle --no-tags; then
        echo -e "$RED\nInitial sync has failed!!$RESET" && echo -e "$BOLD_GREEN\nTrying to sync again with lesser arguments...$RESET\n"

        if ! repo sync -j$CONFIG_SYNC_JOBS; then
            echo -e "$RED\nSyncing has failed completely!$RESET" && echo -e "$BOLD_GREEN\nStarting the build now...$RESET\n"
        else
            SYNC_END=$(TZ=Asia/Dhaka date +"%s")
        fi
    else
        SYNC_END=$(TZ=Asia/Dhaka date +"%s")
    fi

    if [[ -n $SYNC_END ]]; then
        DIFFERENCE=$((SYNC_END - SYNC_START))
        MINUTES=$((($DIFFERENCE % 3600) / 60))
        SECONDS=$(((($DIFFERENCE % 3600) / 60) / 60))

        sync_finished_message="🟢 | <i>Sources synced!!</i>

<b>• ROM:</b> <code>$ROM_NAME</code>
<b>• DEVICE:</b> <code>$DEVICE</code>
<b>• JOBS:</b> <code>$CONFIG_SYNC_JOBS Cores</code>
<b>• DIRECTORY:</b> <code>$(pwd)</code>

<i>Syncing took $MINUTES minutes(s) and $SECONDS seconds(s)</i>"

        edit_message "$sync_finished_message" "$CONFIG_CHATID" "$sync_message_id"
    else
        sync_failed_message="🔴 | <i>Syncing sources failed!!</i>
    
<i>Trying to compile the ROM now...</i>"

        edit_message "$sync_failed_message" "$CONFIG_CHATID" "$sync_message_id"
    fi
fi

if [[ -n $CLEAN ]]; then
    echo -e "$BOLD_GREEN\nNuking the out directory now...$RESET\n"
    rm -rf "out"
fi

# Send a notification that the build process has started.

build_start_message="🟡 | <i>Compiling ROM...</i>

<b>• ROM:</b> <code>$ROM_NAME</code>
<b>• DEVICE:</b> <code>$DEVICE</code>
<b>• JOBS:</b> <code>$CONFIG_COMPILE_JOBS Cores</code>
<b>• TYPE:</b> <code>$([ "$OFFICIAL" == "1" ] && echo "Official" || echo "Unofficial")</code>
<b>• PROGRESS</b>: <code>Lunching...</code>"

build_message_id=$(send_message "$build_start_message" "$CONFIG_CHATID")

BUILD_START=$(TZ=Asia/Dhaka date +"%s")

# Start Compilation. Compile the ROM according to the configuration.
echo -e "$BOLD_GREEN\nSetting up the build environment...$RESET"
source build/envsetup.sh

echo -e "$BOLD_GREEN\nStarting to lunch "$DEVICE" now...$RESET"
lunch "$CONFIG_LUNCH"

if [ $? -eq 0 ]; then
    echo -e "$BOLD_GREEN\nStarting to build now...$RESET"
    mka "$CONFIG_TARGET" -j$CONFIG_COMPILE_JOBS | tee -a "$ROOT_DIRECTORY/build.log" &
else
    echo -e "$RED\nFailed to lunch "$DEVICE"$RESET"

    build_failed_message="🔴 | <i>ROM compilation failed...</i>
    
<i>Failed at lunching $DEVICE...</i>"

    edit_message "$build_failed_message" "$CONFIG_CHATID" "$build_message_id"
    send_sticker "$STICKER_URL" "$CONFIG_CHATID"
    exit 1
fi

# Contiounsly update the progress of the build.
until [ -z "$(jobs -r)" ]; do
    if [ "$(fetch_progress)" = "$previous_progress" ]; then
        continue
    fi

    build_progress_message="🟡 | <i>Compiling ROM...</i>

<b>• ROM:</b> <code>$ROM_NAME</code>
<b>• DEVICE:</b> <code>$DEVICE</code>
<b>• JOBS:</b> <code>$CONFIG_COMPILE_JOBS Cores</code>
<b>• TYPE:</b> <code>$([ "$OFFICIAL" == "1" ] && echo "Official" || echo "Unofficial")</code>
<b>• PROGRESS:</b> <code>$(fetch_progress)</code>"

    edit_message "$build_progress_message" "$CONFIG_CHATID" "$build_message_id"

    previous_progress=$(fetch_progress)

    sleep 5
done

build_progress_message="🟡 | <i>Compiling ROM...</i>

<b>• ROM:</b> <code>$ROM_NAME</code>
<b>• DEVICE:</b> <code>$DEVICE</code>
<b>• JOBS:</b> <code>$CONFIG_COMPILE_JOBS Cores</code>
<b>• TYPE:</b> <code>$([ "$OFFICIAL" == "1" ] && echo "Official" || echo "Unofficial")</code>
<b>• PROGRESS:</b> <code>$(fetch_progress)</code>"

edit_message "$build_progress_message" "$CONFIG_CHATID" "$build_message_id"

# Upload Build. Upload the output ROM ZIP file to the index.
BUILD_END=$(TZ=Asia/Dhaka date +"%s")
DIFFERENCE=$((BUILD_END - BUILD_START))
HOURS=$(($DIFFERENCE / 3600))
MINUTES=$((($DIFFERENCE % 3600) / 60))

if [ -s "out/error.log" ]; then
    # Send a notification that the build has failed.
    build_failed_message="🔴 | <i>ROM compilation failed...</i>
    
<i>Check out the log below!</i>
<code>$(cat out/error.log | sed -n '/Output:/,$p' | sed '1d' | sed 's/\x1b\[[0-9;]*m//g')</code>
"

    edit_message "$build_failed_message" "$CONFIG_ERROR_CHATID" "$build_message_id"
    send_file_to_error_chat "out/error.log" "$CONFIG_ERROR_CHATID"
    send_sticker "$STICKER_URL" "$CONFIG_CHATID"
else
    ota_file=$(ls "$OUT"/*ota*.zip | tail -n -1)
    rm "$ota_file"

    zip_file=$(ls "$OUT"/*$DEVICE*.zip | tail -n -1)

    echo -e "$BOLD_GREEN\nStarting to upload the ZIP file now...$RESET\n"
    mega-whoami > /dev/null # assert mega is logged in
    mega-put "$zip_file"

    zip_file_md5sum=$(md5sum $zip_file | awk '{print $1}')
    zip_file_size=$(ls -sh $zip_file | awk '{print $1}')

    build_finished_message="🟢 | <i>ROM compiled!!</i>

<b>• ROM:</b> <code>$ROM_NAME</code>
<b>• DEVICE:</b> <code>$DEVICE</code>
<b>• TYPE:</b> <code>$([ "$OFFICIAL" == "1" ] && echo "Official" || echo "Unofficial")</code>
<b>• SIZE:</b> <code>$zip_file_size</code>
<b>• MD5SUM:</b> <code>$zip_file_md5sum</code>

<i>Compilation took $HOURS hours(s) and $MINUTES minutes(s)</i>"

    edit_message "$build_finished_message" "$CONFIG_CHATID" "$build_message_id"
    send_sticker "$STICKER_URL" "$CONFIG_CHATID"
    generate_ota_json "$zip_file"
fi

if [[ $POWEROFF == true ]]; then
echo -e "$BOLD_GREEN\nAyo, powering off server...$RESET"
sudo poweroff
fi
