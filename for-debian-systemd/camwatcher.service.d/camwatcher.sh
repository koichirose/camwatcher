#/bin/bash
#
# Command line:
#     bash "/etc/systemd/system/camwatcher.service.d/camwatcher.sh" cron camera01
#     bash "/etc/systemd/system/camwatcher.service.d/camwatcher.sh" start camera01
#     bash "/etc/systemd/system/camwatcher.service.d/camwatcher.sh" stop camera01
#     watch -n 1 "ps waux | grep camwatcher | grep -v grep"
#
# Service:
#     systemctl enable camwatcher@camera01
#     systemctl start camwatcher@camera01
#     systemctl status camwatcher@camera01
#     journalctl -f -u camwatcher@camera01
#     systemctl stop camwatcher@camera01
#
# Prerequisites:
#     [optional] dvr-scan
#     apt-get install -y mediainfo
#     Env vars: Set by camera01.env file
#         FOLDER_TO_WATCH
#         SEND_TELEGRAM_NOTIFICATIONS
#         DVRSCAN_EXTRACT_MOTION_ROI
#         TELEGRAM_BOT_APIKEY
#         TELEGRAM_BOT_ID
#         TELEGRAM_CHAT_ID
#     Get TELEGRAM_CHAT_ID:
#         curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_ID}:${TELEGRAM_BOT_APIKEY}/getUpdates" | grep -o -E '"chat":{"id":[-0-9]*,' | head -n 1
#
# Script Configuration.
FOLDER_MINDEPTH="1"
DELETE_FILE_WHEN_PROCESSED="0"
DELETE_TMP_FILES_WHEN_SENT="1"
FILE_WATCH_PATTERN="*.mp4"
SLEEP_CYCLE_SECONDS="60"
SEND_TELEGRAM_NOTIFICATIONS="0"
#
# Consts: CFS
## This is used to make the notification message silent if anyone is home while the camera caught motion.
G_DP_PRESENCE_ANYONE="/tmp/cfs/dp/presence/anyone"
#
## Settings: Analyze and delete camera footage which contains false alarms
### Check incoming videos if they really contain motion.
### Delete them if no motion is found.
### ROI x,y,w,h derived from VLC snapshot analyzed in ImageGlass
DVRSCAN_PYTHON="/usr/bin/python3"
DVRSCAN_SCRIPT="/home/koichirose/.local/bin/dvr-scan"
#DVRSCAN_EXTRACT_FORMAT="H264"
#DVRSCAN_EXTRACT_FORMAT="MP4V"
DVRSCAN_EXTRACT_MOTION_MIN_EVENT_LENGTH="4"                # default: 2
#
DVRSCAN_EXTRACT_MOTION_THRESHOLD="0.4"                    # default: 0.4
#DVRSCAN_EXTRACT_MOTION_THRESHOLD="0.15"                    # default: 0.15
DVRSCAN_EXTRACT_BEFORE="00:00:01.0000"
DVRSCAN_EXTRACT_AFTER="00:00:03.0000"
###
### For testing purposes only.
#### bash "/home/koichirose/scripts/camwatcher/for-debian-systemd/camwatcher.service.d/camwatcher.sh" cron camera01
##
##
### Check if incoming videos are longer than X seconds.
### Useful for example when Yi Cameras always submit a 59 second video subsequently after
### submitting the short video which contains the motion event.
### Use "0" to forward all video lengths via push notification.
MAX_VIDEO_LENGTH_SECONDS="0"
#
# Runtime Variables.
SCRIPT_FULLFN="$(basename -- "${0}")"
SCRIPT_NAME="${SCRIPT_FULLFN%.*}"
LOGFILE="/tmp/${SCRIPT_NAME}.log"
LOG_MAX_LINES="10000"
#
# -----------------------------------------------------
# -------------- START OF FUNCTION BLOCK --------------
# -----------------------------------------------------
checkFiles ()
{
    # Search for new files.
    L_FILE_LIST="$(find "${FOLDER_TO_WATCH}" -mindepth ${FOLDER_MINDEPTH} -type f \( -name "${FILE_WATCH_PATTERN}" ! -name "*processed*" \) -print | sort -k 1 -n)"
    if [ -z "${L_FILE_LIST}" ]; then
        logAdd "[INFO] checkFiles: No files to process, exiting..."
        return 0
    fi
    echo "${L_FILE_LIST}" | while read file; do
        # Only process files that have not been processed by dvrscan before.
        logAdd ""
        logAdd ""
        logAdd "----------------------"
        logAdd "[INFO] checkFiles: now processing ${file}"
        logAdd "----------------------"
        #if [ ! -s "${file}" ]; then
            #echo "[INFO] checkFiles: Skipping empty file [${file}]"
            #rm -f "${file}"
            #continue
        #fi

        VIDEO_LENGTH_MS="$(mediainfo --Inform="General;%Duration%" "${file}")"
        VIDEO_LENGTH_SECONDS="$((VIDEO_LENGTH_MS/1000))"
        logAdd "[INFO] checkFiles: video length is ${VIDEO_LENGTH_SECONDS}s (${VIDEO_LENGTH_MS}ms)."

        dvr_scan_output=$("${DVRSCAN_PYTHON}" "${DVRSCAN_SCRIPT}" -i "${file}" -so -l "${DVRSCAN_EXTRACT_MOTION_MIN_EVENT_LENGTH}" ${DVRSCAN_EXTRACT_MOTION_ROI} -t "${DVRSCAN_EXTRACT_MOTION_THRESHOLD}" -tb "${DVRSCAN_EXTRACT_BEFORE}" -tp "${DVRSCAN_EXTRACT_AFTER}")
        if ( ! echo "$dvr_scan_output" | grep "] Detected" ); then
            logAdd "[INFO] checkFiles: dvr-scan reported no motion - [${file}]. Skipping."
            continue
        else
            # 00:00:00.650,00:00:01.900,00:00:05.650,00:00:09.900
            timestamps="${dvr_scan_output##*$'\n'}"
            # split on comma
            timestamps_arr=(${timestamps//\,/ })
            #IFS=',' read -r -a timestamps_arr <<< "$timestamps"
            
            #echo "x"
            #echo "$timestamps"
            #echo "y"

            arraylength=${#timestamps_arr[@]}
            #echo "timestamps_arr"
            #echo "${timestamps_arr[*]}"
            #echo "arraylength"
            #echo "$arraylength"
            # loop every two values
            ffmpeg_splits=()
            TMP_FFMPEG_SPLIT_BASE="/tmp/ffmpeg_motion_"
            for (( i=0; i<${arraylength}; i+=2 ));
            do
                TMP_FFMPEG_SPLIT="${TMP_FFMPEG_SPLIT_BASE}${i}.mp4"
                TMP_FFMPEG_FINAL="${TMP_FFMPEG_SPLIT_BASE}${i}.mp4"
                #from="${timestamps[$i]}"
                #to="${timestamps[$i+1]}"
                from="${timestamps_arr[$i]}"
                to="${timestamps_arr[$i+1]}"
                logAdd "Splitting video from ${from} to ${to}"
                #echo "from"
                #echo "$from"
                #echo "to"
                #echo "$to"
                ffmpeg -y -nostdin -ss "${from}" -to "${to}" -i "${file}" -c copy "${TMP_FFMPEG_SPLIT}"
                if [ -f "$TMP_FFMPEG_SPLIT" ]; then
                    ffmpeg_splits+=($TMP_FFMPEG_SPLIT)
                fi
            done
            if [ "${#ffmpeg_splits[@]}" -gt "1" ]; then
                echo "ffmpeg_splits"
                #echo "${ffmpeg_splits[*]}"
                printf "%s\n" "${ffmpeg_splits[@]}"
                TMP_FFMPEG_FINAL="${TMP_FFMPEG_SPLIT_BASE}final.mp4"
                ffmpeg -y -nostdin -f concat -safe 0 -i <(for f in "${ffmpeg_splits[@]}"; do echo "file '$f'"; done) -c copy $TMP_FFMPEG_FINAL
            fi
        fi
        if [ "${SEND_TELEGRAM_NOTIFICATIONS}" = "1" ]; then
            if ( sendTelegramNotification -- "${TMP_FFMPEG_FINAL}" ); then
                logAdd "[INFO] checkFiles: sendTelegramNotification SUCCEEDED - [${TMP_FFMPEG_FINAL}]."
            else
                logAdd "[ERROR] checkFiles: sendTelegramNotification FAILED - [${TMP_FFMPEG_FINAL}]."
            fi
        else
            logAdd "[INFO] checkFiles: SKIPPING sendTelegramNotification."
        fi
        if [ "${DELETE_FILE_WHEN_PROCESSED}" = "1" ]; then
            rm -f "${file}"
        else
            processed_file="$(echo "${file}" | sed -e "s/.mp4$/_processed.mp4/")"
            mv "${file}" "${processed_file}"
        fi
        if [ "${DELETE_TMP_FILES_WHEN_SENT}" = "1" ]; then
            rm "${TMP_FFMPEG_SPLIT_BASE}"*
        fi
        logAdd "----------------------"
        logAdd "finished processing ${file}"
        logAdd "----------------------"
    done
    #
    # Delete empty sub directories
    if [ ! -z "${FOLDER_TO_WATCH}" ]; then
        find "${FOLDER_TO_WATCH}/" -mindepth 1 -type d -empty -delete
    fi
    #
    return 0
}


logAdd ()
{
    TMP_DATETIME="$(date '+%Y-%m-%d [%H-%M-%S]')"
    TMP_LOGSTREAM="$(tail -n ${LOG_MAX_LINES} ${LOGFILE} 2>/dev/null)"
    echo "${TMP_LOGSTREAM}" > "$LOGFILE"
    echo "${TMP_DATETIME} $*" | tee -a "${LOGFILE}"
    return 0
}


sendTelegramMediaGroup ()
{
    #
    # Usage:            sendTelegramMediaGroup "[TEXT_CAPTION]" "[ATTACHMENT1_FULLFN]" "[ATTACHMENT2_FULLFN]"
    #                     Paramter #2 is optional.
    # Example:            sendTelegramMediaGroup "/tmp/test1.jpg" "/tmp/test2.jpg"
    # Purpose:
    #     Send push message to Telegram Bot Chat
    #
    # Global Variables
    #     [IN] TELEGRAM_BOT_ID
    #     [IN] TELEGRAM_BOT_APIKEY
    #     [IN] TELEGRAM_CHAT_ID
    #
    # Returns:
    #     "0" on SUCCESS
    #     "1" on FAILURE
    #
    # Variables.
    TMP_TEXT_CAPTION="${1}"
    #
    # Add first attachment.
    STN_ATT1_FULLFN="${2}"
    if [ ! "${STN_ATT1_FULLFN##*.}" = "jpg" ]; then
        return 1
    fi
    TMP_MEDIA_ARRAY="{\"type\":\"photo\",\"media\":\"attach://photo_1\",\"caption\":\"${TMP_TEXT_CAPTION}\"}"
    TMP_ATTACHMENT_ARRAY="-F "\"photo_1=@${STN_ATT1_FULLFN}\"""
    #
    # Add second attachment if applicable.
    STN_ATT2_FULLFN="${3}"
    if [ ! -z "${STN_ATT2_FULLFN}" ] && [ ! "${STN_ATT2_FULLFN##*.}" = "jpg" ]; then
        return 1
    fi
    if [ ! -z "${STN_ATT2_FULLFN}" ]; then
        TMP_MEDIA_ARRAY="${TMP_MEDIA_ARRAY},{\"type\":\"photo\",\"media\":\"attach://photo_2\",\"caption\":\"\"}"
        TMP_ATTACHMENT_ARRAY="${TMP_ATTACHMENT_ARRAY} -F "\"photo_2=@${STN_ATT2_FULLFN}\"""
    fi
    #
    CURL_RESULT="$(eval curl -q \
            --insecure \
            --max-time \""60\"" \
            -F "media='[${TMP_MEDIA_ARRAY}]'" \
            ${TMP_ATTACHMENT_ARRAY} \
             "\"https://api.telegram.org/bot${TELEGRAM_BOT_ID}:${TELEGRAM_BOT_APIKEY}/sendMediaGroup?chat_id=${TELEGRAM_CHAT_ID}&disable_notification=true\"" \
             2> /dev/null)"
    if ( ! echo "${CURL_RESULT}" | grep -Fiq "\"ok\":true" ); then
        if ( echo "${CURL_RESULT}" | grep -Fiq "\"error_code\":413," ); then
            logAdd "[ERROR] sendTelegramMediaGroup: Attachment too large. Deleting and skipping."
            rm -f "${STN_ATT1_FULLFN}"
            if [ ! -z "${STN_ATT2_FULLFN}" ]; then
                rm -f "${STN_ATT2_FULLFN}"
            fi
        else
            logAdd "[DEBUG] sendTelegramMediaGroup: API_RESULT=${CURL_RESULT}"
        fi
        return 1
    fi
    #
    # Return SUCCESS.
    return 0
}


sendTelegramNotification ()
{
    #
    # Usage:            sendTelegramNotification "[PN_TEXT]" "[ATTACHMENT_FULLFN]"
    # Example:            sendTelegramNotification "Test push message" "/tmp/test.txt"
    # Purpose:
    #     Send push message to Telegram Bot Chat
    #
    # Returns:
    #     "0" on SUCCESS
    #     "1" on FAILURE
    #
    # Global Variables
    #     [IN] TELEGRAM_BOT_ID
    #     [IN] TELEGRAM_BOT_APIKEY
    #     [IN] TELEGRAM_CHAT_ID
    #
    # Variables.
    STN_TEXT="${1}"
    STN_TEXT="${STN_TEXT//\"/\\\"}"
    STN_ATT_FULLFN="${2}"
    #
    if [ "${STN_TEXT}" = "--" ]; then
        STN_TEXT=""
    fi
    if [ -z "${STN_TEXT}" ] && [ -z "${STN_ATT_FULLFN}" ]; then
        return 1
    fi
    #
    #
    # If anyone is home, plan a silent notification.
    STN_DISABLE_NOTIFICATION="false"
    if ( cat "${G_DP_PRESENCE_ANYONE}" 2>/dev/null | grep -Fiq "1" ); then
        STN_DISABLE_NOTIFICATION="true"
    fi
    #
    if [ ! -z "${STN_TEXT}" ]; then
        if ( ! eval curl -q \
                --insecure \
                --max-time \""60\"" \
                 "\"https://api.telegram.org/bot${TELEGRAM_BOT_ID}:${TELEGRAM_BOT_APIKEY}/sendMessage?chat_id=${TELEGRAM_CHAT_ID}&disable_notification=${STN_DISABLE_NOTIFICATION}&text=${STN_TEXT}\"" \
                 2> /dev/null \| grep -Fiq "\"ok\\\":true\"" ); then
            return 1
        fi
    fi
    #
    if [ ! -z "${STN_ATT_FULLFN}" ]; then
        if [ "${STN_ATT_FULLFN##*.}" = "jpg" ]; then
            CURL_RESULT="$(eval curl -q \
                    --insecure \
                    --max-time \""60\"" \
                    -F "\"photo=@${STN_ATT_FULLFN}\"" \
                     "\"https://api.telegram.org/bot${TELEGRAM_BOT_ID}:${TELEGRAM_BOT_APIKEY}/sendPhoto?chat_id=${TELEGRAM_CHAT_ID}&disable_notification=${STN_DISABLE_NOTIFICATION}\"" \
                     2> /dev/null)"
            if ( ! echo "${CURL_RESULT}" | grep -Fiq "\"ok\":true" ); then
                if ( echo "${CURL_RESULT}" | grep -Fiq "\"error_code\":413," ); then
                    logAdd "[ERROR] sendTelegramNotification: Attachment too large. Deleting and skipping."
                    rm -f "${STN_ATT_FULLFN}"
                else
                    logAdd "[DEBUG] sendTelegramNotification: API_RESULT=${CURL_RESULT}"
                fi
                return 1
            fi
        elif [ "${STN_ATT_FULLFN##*.}" = "mp4" ]; then
            CURL_RESULT="$(eval curl -q \
                    --insecure \
                    --max-time \""60\"" \
                    -F "\"video=@${STN_ATT_FULLFN}\"" \
                     "\"https://api.telegram.org/bot${TELEGRAM_BOT_ID}:${TELEGRAM_BOT_APIKEY}/sendVideo?chat_id=${TELEGRAM_CHAT_ID}&disable_notification=${STN_DISABLE_NOTIFICATION}\"" \
                     2> /dev/null)"
            if ( ! echo "${CURL_RESULT}" | grep -Fiq "\"ok\":true" ); then
                if ( echo "${CURL_RESULT}" | grep -Fiq "\"error_code\":413," ); then
                    logAdd "[ERROR] sendTelegramNotification: Attachment too large. Deleting and skipping."
                    rm -f "${STN_ATT_FULLFN}"
                else
                    logAdd "[DEBUG] sendTelegramNotification: API_RESULT=${CURL_RESULT}"
                fi
                return 1
            fi
        else
            # Wrong file extension.
            return 1
        fi
        #
    fi
    #
    # Return SUCCESS.
    return 0
}


serviceMain ()
{
    #
    # Usage:        serviceMain    [--one-shot]
    # Called By:    MAIN
    #
    logAdd "[INFO] === SERVICE START ==="
    # sleep 10
    while (true); do
        # Check if folder exists.
        if [ ! -d "${FOLDER_TO_WATCH}" ]; then 
            mkdir -p "${FOLDER_TO_WATCH}"
        fi
        # 
        # Ensure correct file permissions.
        if ( ! stat -c %a "${FOLDER_TO_WATCH}/" | grep -q "^777$"); then
            logAdd "[WARN] Adjusting folder permissions to 0777 ..."
            chmod -R 0777 "${FOLDER_TO_WATCH}"
        fi
        #
        # logAdd "[INFO] checkFiles S"
        checkFiles
        # logAdd "[INFO] checkFiles E"
        #
        if [ "${1}" = "--one-shot" ]; then
            break
        fi
        #
        sleep ${SLEEP_CYCLE_SECONDS}
    done
    return 0
}
# ---------------------------------------------------
# -------------- END OF FUNCTION BLOCK --------------
# ---------------------------------------------------
#
# Check shell
if [ ! -n "$BASH_VERSION" ]; then
    logAdd "[ERROR] Wrong shell environment, please run with bash."
    exit 99
fi
#
SCRIPT_PATH="$(dirname "$(realpath "${0}")")"
ENVIRONMENT_FILE="${SCRIPT_PATH}/${2}.env"
if [ -z "${2}" ] || [ ! -f "${ENVIRONMENT_FILE}" ]; then
    logAdd "[ERROR] Environment file missing: ENVIRONMENT_FILE=[${ENVIRONMENT_FILE}]. Stop."
    exit 99
fi
source "${ENVIRONMENT_FILE}"
#
if [ -z "${FOLDER_TO_WATCH}" ]; then
    logAdd "[ERROR] Env var not set: FOLDER_TO_WATCH. Stop."
    exit 99
fi
#
#
if [ -z "${TELEGRAM_BOT_ID}" ] || [ -z "${TELEGRAM_BOT_APIKEY}" ] || [ -z "${TELEGRAM_CHAT_ID}" ]; then
    logAdd "[ERROR] Telegram bot config env vars missing. Stop."
    exit 99
fi
#
#if [ "${#DVRSCAN_EXTRACT_MOTION_ROI_ARRAY[*]}" -eq 0 ]; then
    #logAdd "[ERROR] Env var array not set: DVRSCAN_EXTRACT_MOTION_ROI_ARRAY. Stop."
    #exit 99
#fi
#
# Runtime Variables.
LOG_SUFFIX="$(echo "${FOLDER_TO_WATCH}" | sed -e "s/^.*\///")"
LOGFILE="/tmp/${SCRIPT_NAME}_${LOG_SUFFIX}.log"
#
DVRSCAN_EXTRACT_MOTION_ROI=""
#DVRSCAN_EXTRACT_MOTION_ROI="-roi"
#for roi in "${DVRSCAN_EXTRACT_MOTION_ROI_ARRAY[@]}"; do
    #DVRSCAN_EXTRACT_MOTION_ROI="${DVRSCAN_EXTRACT_MOTION_ROI} ${roi}"
#done
logAdd "[INFO] DVRSCAN_EXTRACT_MOTION_ROI=[${DVRSCAN_EXTRACT_MOTION_ROI}]"
#
# set +m
trap "" SIGHUP
trap "trap - SIGTERM && kill -- -$$" SIGINT SIGTERM EXIT
#
# Check if "dvr-scan" is available
if ( ! "${DVRSCAN_PYTHON}" "${DVRSCAN_SCRIPT}" --version > /dev/null 2>&1 ); then
    logAdd "[WARN] dvr-scan is not installed correctly. Setting DVRSCAN_MOTION_ANALYSIS=0."
    DVRSCAN_MOTION_ANALYSIS="0"
fi
#
# Check if "ffmpeg" is available
if ( ! ffmpeg -version > /dev/null 2>&1 ); then
    logAdd "[WARN] ffmpeg is not installed correctly."
fi
#
# Check if "mediainfo" is available
if [ "${MAX_VIDEO_LENGTH_SECONDS}" -gt "0" ]; then
    if ( ! mediainfo --version > /dev/null 2>&1 ); then
        logAdd "[WARN] mediainfo is not available. Install it with 'apt-get install -y mediainfo'. Setting MAX_VIDEO_LENGTH_SECONDS=0 to disable the feature."
        MAX_VIDEO_LENGTH_SECONDS="0"
    fi
fi
#
if [ "${1}" = "cron" ]; then
    serviceMain --one-shot
    logAdd "[INFO] === SERVICE STOPPED ==="
    exit 0
elif [ "${1}" = "start" ]; then
    serviceMain &
    #
    # Wait for kill -INT.
    wait
    exit 0
elif [ "${1}" = "stop" ]; then
    ps w | grep -v grep | grep "$(basename -- ${SHELL}) ${0}" | sed 's/ \+/|/g' | sed 's/^|//' | cut -d '|' -f 1 | grep -v "^$$" | while read pidhandle; do
        echo "[INFO] Terminating old service instance [${pidhandle}] ..."
        kill -INT "${pidhandle}"
    done
    #
    # Check if parts of the service are still running.
    if [ "$(ps w | grep -v grep | grep "$(basename -- ${SHELL}) ${0}" | sed 's/ \+/|/g' | sed 's/^|//' | cut -d '|' -f 1 | grep -v "^$$" | wc -l)" -gt 1 ]; then
        logAdd "[ERROR] === SERVICE FAILED TO STOP ==="
        exit 99
    fi
    logAdd "[INFO] === SERVICE STOPPED ==="
    exit 0
fi
#
logAdd "[ERROR] Parameter #1 missing."
logAdd "[INFO] Usage: ${SCRIPT_FULLFN} {cron|start|stop}"
exit 99
