#!/bin/bash
#
# Author: Maruthy Mentireddi 
# Current Version: v 3.0
# Initial Version: v 1.24
# Date:   2014-03-12
# Updates:
# 03/12/2014  Maruthy Mentireddi  RFC9340
# 07/25/2014  Maruthy Mentireddi
# 08/26/2014  Manish Kumar
# 11/28/2014  Rémi Grenier
# 06/22/2015  Rémi Grenier

############################ Configuration ######################################

#Load user-defined email recipients
. $HOME/.profile > /dev/null 2>&1



echo "Enabled/Disable features"
#Enabled/Disable features
MARK_COPIED_AUDIT_LOGS=y
PREVIOUS_HOURS_AUDIT_LOG_ROLLOVER=y
MISSING_AUDIT_LOG_GENERATION=y
ERROR_NOTIFICATION=y
SUCCESS_NOTIFICATION=n
echo "Notifications"
#Notifications
EMAIL_NOTIFICATION=y
MAILER=`which mailx`
NOTIFICATION_ADDRESS=${NOTIFICATION_ADDRESS-"bhanuprakash.boya@gmail.com"}
TRANSFER_DATE=`date "+%Y-%m-%d %H:%M %p"`

echo "snmp traps"
# SNMP traps
SNMP_TRAPS=y
APP_NOTIFICATION_OID=1.3.6.1.4.1.29088.2.1.0.1
APP_NAME_OID=1.3.6.1.4.1.29088.2.1.1.1.0
RESOURCE_OID=1.3.6.1.4.1.29088.2.1.1.2.0
SEVERITY_OID=1.3.6.1.4.1.29088.2.1.1.3.0
MESSAGE_OID=1.3.6.1.4.1.29088.2.1.1.4.0
DOCUMENTATION_OID=1.3.6.1.4.1.29088.2.1.1.5.0
SNMP_APP_NAME="MIS Xfer Scripts"
SNMP_COMMUNITY=nuance
SNMP_DOCUMENTATION="https://svwiki.nuance.com/wiki/pmwiki.php/Alerts/MISXferScripts-TransferToDATHost"
SNMP_TRAP_HOST=trap-vhost
SNMP_INFO=2
SNMP_WARNING=3
SNMP_ERROR=4
SNMP_CRITICAL=5
MISSING_AUDIT_LOGS_SEVERITY=$SNMP_ERROR

echo "ssh attribbutes"
#SSH
SSH_USER="bhanu"
SSH_OPTS="-o LogLevel=ERROR -o PasswordAuthentication=no -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ServerAliveInterval=30"
TARGET_HOSTNAME="centos7-host"

echo "Rollover"
#Rollover
AUDIT_MAX_PER_HOUR=1000
PREVIOUS_HOURS_TO_HANDLE=24

echo "setup logging"
#Setup Logging
SCRIPT_FILENAME=`readlink -f "${BASH_SOURCE[0]}"`
SCRIPT_NAME=`basename $SCRIPT_FILENAME | cut -d. -f1`
LOG_DIR=/var/log/nuance/${SCRIPT_NAME}
mkdir -p $LOG_DIR
LOG_FILENAME="$LOG_DIR/mis_transfer_logs.log.$(date +\%Y-\%m-\%d_\%H-\%M-\%S)"
eval > $LOG_FILENAME 2>&1
chmod g+r $LOG_FILENAME

echo "Topic stating"
TOPIC="Audit logs transfer to DAT host"

echo "functions start"
############################## Functions ########################################
echo "Enable"
isEnabled() {
  feature=$1
  [[ "x${!feature}" == "xy" ]]
}

isEmpty() {
  varContent=${!1}
  [[ "${#varContent}" -eq 0 ]]
}

isNotEmpty() {
  varContent=${!1}
  [[ "${#varContent}" -ne 0 ]]
}

isTrue() {
  [[ "$1" -eq 0 ]]
}

isFalse() {
  [[ "$1" -ne 0 ]]
}

logError() {
  echo "`date +%T` - ERROR: $1 - Return Code $2"
}

echo "Enable"
sendEmail() {
  SUBJECT="$2 ($1)"
  echo -e "${@:3}" | $MAILER -s "$SUBJECT" $NOTIFICATION_ADDRESS
}

echo "send SnmpTrap"
sendSnmpTrap() {
  echo "send SnmpTrap"
  severity=$1
  resource=$2
  message=$3
  snmptrap -v 2c -c $SNMP_COMMUNITY $SNMP_TRAP_HOST '' $APP_NOTIFICATION_OID \
        $APP_NAME_OID s "$SNMP_APP_NAME"   \
        $RESOURCE_OID s "$resource"  \
        $SEVERITY_OID i $severity  \
        $MESSAGE_OID s "${message//'\n'/ }"  \
        $DOCUMENTATION_OID s "$SNMP_DOCUMENTATION"
}

handleReturnCode() {
  echo "handle returncode"
  local returnCode=$1
  if [ $returnCode -eq 0 ]; then
    return 0;
  fi

  local errorMessage=$3
  echo -e "`date +%T` - ERROR: $errorMessage - Return Code $returnCode"
  
  if isEnabled ERROR_NOTIFICATION ; then
    local notificationSubject=$2
    
    local notificationMessage="During transfer at $TRANSFER_DATE on server '$HOSTNAME' an error occurred.\n\n$errorMessage\n\nFor further Investigation, please check the log file $LOG_FILENAME located on $HOSTNAME."
    if isEnabled SNMP_TRAPS ; then
      sendSnmpTrap $SNMP_ERROR "$notificationSubject" "$notificationMessage"
    fi
    if isEnabled EMAIL_NOTIFICATION ; then
      sendEmail "ERROR" "$notificationSubject" "Dear Team,\n\n$notificationMessage\n\nThank you.\nmistrans"
    fi
  fi
  exit $returnCode
}

runOnRemoteServer() {
  
  echo "ssh remote server running"
  ssh $SSH_OPTS $SSH_USER@$TARGET_HOSTNAME $@
  return $?
}

makeRemoteDestination() {
  echo "remoreDestination"
  local command="mkdir -p $1"

  runOnRemoteServer $command

  handleReturnCode $? "$TOPIC" \
                   "Failed to remotely run the command: '$command' from server '$HOSTNAME' on '$TARGET_HOSTNAME'.\nAborting transfer and exiting.\n\nPlease check the '$TARGET_HOSTNAME' SSH Status/Connectivity."
}

echo "Copy files to Target"
copyToTarget() {
  echo "copy to target file"
  local auditLog=$1
  local targetPath=$2
  echo "Files need to be transfer"
  local command="scp $SSH_OPTS $auditLog $SSH_USER@$TARGET_HOSTNAME:$targetPath"
  `$command`
  
  handleReturnCode $? "$TOPIC" \
                   "Failed to execute: '$command'.\nWill retry to send $auditLog file from $HOSTNAME to '$TARGET_HOSTNAME' in next cycle."
}



findRolledOverAuditLogs() {
  echo "find rollerover function"
  local source=$1
  local patterns=${@:2}
  local pathDepth=`grep -o "/" <<< "$source" | wc -l`
  
  unset ALL_FOUND_AUDIT_LOGS
  
  if [ ! -d "$source" ]; then
    echo "Skipping $source because it does not exist."
    return 1
  fi

  echo "Searching for $patterns in $source."
  local audit_logs_found=
  for pattern in $patterns ; do
    pattern="${pattern//'|'/ -o -name }"
    audit_logs_found=`find $source -maxdepth $pathDepth -type f \( -name $pattern \) \( ! -name '*.SENT' ! -name '*managed-crypto*' \)`
    if isNotEmpty audit_logs_found ; then
      ALL_FOUND_AUDIT_LOGS="$ALL_FOUND_AUDIT_LOGS $audit_logs_found"
    fi
  done
  ALL_FOUND_AUDIT_LOGS=($ALL_FOUND_AUDIT_LOGS)

  if isEmpty ALL_FOUND_AUDIT_LOGS ; then
    echo "No audit logs were found."
  else
    echo "Audit log(s) were found: ${ALL_FOUND_AUDIT_LOGS[@]}"
  fi
}

findAuditLogs() {
  echo "find auditLogs"
  local source=$1
  local patterns=${@:2}
  local pathDepth=`grep -o "/" <<< "$source" | wc -l`
  
  unset ALL_FOUND_AUDIT_LOGS
  
  if [ ! -d "$source" ]; then
    echo "Skipping $source because it does not exist."
    return 1
  fi

  echo "Searching for $patterns in $source."
  local audit_logs_found=
  for pattern in $patterns ; do
    pattern="${pattern//'|'/ -o -name }"
    minAge=$((10#`date +%M`+1))
    audit_logs_found=`find $source -maxdepth $pathDepth -mmin +$minAge -type f \( -name $pattern \) \( ! -name '*.SENT' ! -name '*managed-crypto*' \)`
    if isNotEmpty audit_logs_found ; then
      ALL_FOUND_AUDIT_LOGS="$ALL_FOUND_AUDIT_LOGS $audit_logs_found"
    fi
  done
  ALL_FOUND_AUDIT_LOGS=($ALL_FOUND_AUDIT_LOGS)

  if isEmpty ALL_FOUND_AUDIT_LOGS ; then
    echo "No audit logs were found."
  else
    echo "Audit log(s) were found: ${ALL_FOUND_AUDIT_LOGS[@]}"
  fi
}

findTemplateAuditLogs() {
  local source=$1
  local patterns=${@:2}
  local pathDepth=`grep -o "/" <<< "$source" | wc -l`

  unset ALL_FOUND_AUDIT_LOGS

  if [ ! -d "$source" ]; then
    return 1
  fi

  echo "Searching for $patterns in $source."
  local auditLogsFound=
  for pattern in $patterns ; do
    #Split in individual groups and retrieve first match 
    local subPatterns=`echo "$pattern" | tr '|' ' '`
    for subPattern in $subPatterns ; do
      auditLogsFound=`find $source -maxdepth $pathDepth -type f \( -name $subPattern \) \( ! -name '*managed-crypto*' \) -printf "%T@ %p\n" | sort -n | cut -d ' ' -f 2 | tail -2 | sort -n | tail -1`
      if isNotEmpty auditLogsFound ; then
        ALL_FOUND_AUDIT_LOGS="$ALL_FOUND_AUDIT_LOGS $auditLogsFound"
        break
      fi
    done
  done
  ALL_FOUND_AUDIT_LOGS=($ALL_FOUND_AUDIT_LOGS)

  if isEmpty ALL_FOUND_AUDIT_LOGS ; then
    echo "No audit logs templates were found."
  else
    echo "Audit log(s) template(s) were found: ${ALL_FOUND_AUDIT_LOGS[@]}"
  fi
}

copyAuditLogs() {
  echo "copy to audit log"
  remoteDestination=$1
  makeRemoteDestination $remoteDestination

  #Remove duplicates
  ALL_FOUND_AUDIT_LOGS=($(printf "%s\n" "${ALL_FOUND_AUDIT_LOGS[@]}" | sort -u))

  if isNotEmpty ALL_FOUND_AUDIT_LOGS ; then
    echo "Copying ${#ALL_FOUND_AUDIT_LOGS[@]} audit log(s) from $HOSTNAME to $remoteDestination."
  fi
  for auditLog in ${ALL_FOUND_AUDIT_LOGS[@]} ; do
    local auditLogTarget="$remoteDestination/$HOSTNAME."`basename $auditLog`
    copyToTarget $auditLog $auditLogTarget 
    local logWasCopied=$?
    if isTrue $logWasCopied && isEnabled MARK_COPIED_AUDIT_LOGS ; then
      cp -p $auditLog $auditLog.SENT
      touch $auditLog.SENT
      handleReturnCode $? "$TOPIC" \
                          "Failed to rename: '$auditLog' to '$auditLog.SENT' on $HOSTNAME.\nAborting transfer and exiting.\n\nPlease manually check the audit logs on $HOSTNAME."
      rm -f $auditLog
    fi
  done
}

isAuditLogNameTaken() {
  rolledOverName=$1
  if [ -e "$rolledOverName" ] ; then
    return 0
  fi
  if isEnabled MARK_COPIED_AUDIT_LOGS && [ -e "$rolledOverName.SENT" ] ; then
    return 0
  fi
  return 1
}

rolloverAuditLogs() {
  echo "About to rollover ${#ALL_FOUND_AUDIT_LOGS[@]} audit logs."
  local rolledOverAuditLogs=
  
  for auditLog in ${ALL_FOUND_AUDIT_LOGS[@]} ; do
    timestamp=`date -r "$auditLog" +"%Y-%m-%d-%H"`
    rolledOverName=$auditLog.$timestamp
    local auditIndex=1
    while isAuditLogNameTaken $rolledOverName ; do
      rolledOverName=${auditLog}.${timestamp}_$auditIndex
      auditIndex=$(($auditIndex+1))
      if [ "$auditIndex" -gt $AUDIT_MAX_PER_HOUR ]; then
        handleReturnCode 3 "$TOPIC" \
                         "Failed to rollover: '$auditLog' on $HOSTNAME because all expected names were already taken.\nLast try was for a rollover name was: $rolledOverName).\nAborting transfer and exiting.\n\nPlease manually check the audit logs on $HOSTNAME."
      fi
    done
    cp -p $auditLog $rolledOverName
    handleReturnCode $? "$TOPIC" \
                     "Failed to rollover: '$auditLog' on $HOSTNAME it could not be renamed as: $rolledOverName).\nAborting transfer and exiting.\n\nPlease manually check the audit logs on $HOSTNAME."
    rm -f $auditLog
    rolledOverAuditLogs="$rolledOverAuditLogs $rolledOverName"
  done
  ALL_FOUND_AUDIT_LOGS=($rolledOverAuditLogs)
  echo "${#ALL_FOUND_AUDIT_LOGS[@]} audit log(s) were rolled over."
}

findAndCopyAuditLogs() {
  echo "find and copy audit logs"
  local auditLogSources=($1)
  local remoteDestination=$2
  local auditLogPatterns=${@:3}
  
  #Update patterns to match audit logs with timestamps
  rolledOverAuditLogPatterns=( "${auditLogPatterns/%/.*}" )
  rolledOverAuditLogPatterns=( "${rolledOverAuditLogPatterns[@]// /.* }" )
  rolledOverAuditLogPatterns=( "${rolledOverAuditLogPatterns[@]//|/.*|}" )
    
  local auditLogsWereFound=1
  for auditLogSource in ${auditLogSources[@]} ; do
    findRolledOverAuditLogs $auditLogSource $rolledOverAuditLogPatterns
    if isNotEmpty ALL_FOUND_AUDIT_LOGS ; then
      echo "auditlogs"
      copyAuditLogs $remoteDestination
      auditLogsWereFound=0
    fi
    if isEnabled PREVIOUS_HOURS_AUDIT_LOG_ROLLOVER ; then
      echo "Searching audit logs to rollover in $auditLogSource."
      findAuditLogs $auditLogSource $auditLogPatterns
      if isNotEmpty ALL_FOUND_AUDIT_LOGS ; then
        rolloverAuditLogs
        echo "auditlogs2"
        copyAuditLogs $remoteDestination
      fi
    fi
  done
  
  if isFalse $auditLogsWereFound ; then
    echo "No audit logs found in $auditLogSources."
  fi
  echo
  return $auditLogsWereFound
}

findGenerateAndCopyAuditLogs() {
  local componentName=$1
  local auditLogSources=($2)
  local remoteDestination=$3
  local auditLogPatterns=${@:4}

  findAndCopyAuditLogs "${@:2}"
  local auditLogsWereFound=$?
  local auditLogsWereGenerated=1

  for auditLogSource in ${auditLogSources[@]} ; do
    if [ ! -d $auditLogSource ] ; then
      continue
    fi
    if isEnabled MISSING_AUDIT_LOG_GENERATION && isFalse auditLogsWereGenerated ; then
      echo "Looking to generate missing audit logs in $auditLogSource."
      
      unset generatedFiles
      
      local templateAuditLogPatterns=( "${auditLogPatterns/%/.*}" )
      templateAuditLogPatterns=( "${templateAuditLogPatterns[@]// /.* }" )
      templateAuditLogPatterns=( "${templateAuditLogPatterns[@]//|/.*|}" )
      
      findTemplateAuditLogs $auditLogSource ${templateAuditLogPatterns[@]}
      templateAuditLogs=("${ALL_FOUND_AUDIT_LOGS[@]}")
      
      unset ALL_FOUND_AUDIT_LOGS
      for templateAuditLog in ${templateAuditLogs[@]} ; do
        local ownerAttributes=`find $templateAuditLog -maxdepth 0 -printf '%u:%g\n'`
        #Build missing audit log filename
        if isEnabled MARK_COPIED_AUDIT_LOGS ; then
          #Remove .SENT
          templateAuditLog=${templateAuditLog%.*}
        fi
        
        local previousHour=1
        while [ $previousHour -lt $PREVIOUS_HOURS_TO_HANDLE ]; do
          #Replace timestamp from template
          timestamp=`date -d "$previousHour hours ago" +%Y-%m-%d-%H`
          auditLog=${templateAuditLog%.*}.$timestamp
          if [ "$auditLog" == "$templateAuditLog" ] ; then
            break
          fi
          if [ -e $auditLog ] ; then
            break
          fi
          if isEnabled MARK_COPIED_AUDIT_LOGS ; then
            if [ -e $auditLog.SENT ] ; then
              break
            fi
          fi
          echo "Creating missing audit log: $auditLog"
          touch -t `date --date="$previousHour hours ago" +"%Y%m%d%H%M"` $auditLog
          chown $ownerAttributes $auditLog
          ALL_FOUND_AUDIT_LOGS="$ALL_FOUND_AUDIT_LOGS $auditLog"
          previousHour=$(($previousHour+1))
        done
      done
      
      ALL_FOUND_AUDIT_LOGS=( $ALL_FOUND_AUDIT_LOGS )
      if isEmpty ALL_FOUND_AUDIT_LOGS ; then
        echo "No audit logs were generated in $auditLogSource."
        echo
        break
      fi
      
      copyAuditLogs $remoteDestination
      auditLogsWereGenerated=0
      local notificationMessage="During transfer at $TRANSFER_DATE on server '$HOSTNAME', ${#ALL_FOUND_AUDIT_LOGS[@]} audit log(s) were missing and default empty audit log(s) were created to compensate:\n`echo ${ALL_FOUND_AUDIT_LOGS[@]}| tr '[ ]' '[,\n\n]'`."
      if isEnabled SNMP_TRAPS ; then
        sendSnmpTrap $MISSING_AUDIT_LOGS_SEVERITY "Missing Audit logs ($componentName)" "$notificationMessage"
      fi
      if isEnabled EMAIL_NOTIFICATION ; then
        sendEmail "WARNING" "Missing Audit logs" "Dear Team,\n\n$notificationMessage\n\nThank you.\nmistrans"
      fi
      echo
    fi
  done
}

################################ Main ##########################################

#Print command traces before executing command.
#set -x

#Disable pathname expansion.
set -f

echo "Notification address is: $NOTIFICATION_ADDRESS"
echo
echo "Starting $TOPIC at `date +%T`"
echo

echo "*** Copy EPS audit logs ***"
MISSING_AUDIT_LOGS_SEVERITY=$SNMP_CRITICAL
findGenerateAndCopyAuditLogs EPS '/var/audit/nuance/eps /var/log/nuance/eps/audit' "~/app_logs/eps-encrypt" \
                     audit-eps-inbound-v*.csv \
                     audit-eps-outbound-v*.csv \
                     audit-eps-external-v*.csv
 
MISSING_AUDIT_LOGS_SEVERITY=$SNMP_ERROR
echo

echo "*** Copy TEP audit logs ***"

echo "find gen file running"

findGenerateAndCopyAuditLogs TEP "/var/log/spinvox/edmund/QCErrors/spinvox/$(date +\%Y)/$(date +\%m)/$(date +\%d) /var/log/spinvox/edmund/audit" "~/app_logs/tenzing-endpoint" \
		     'mis_transfer_logs*|mis_transfer_logs*' \
                     'audit-tenzing-endpoint-messages-v*.csv|audit-tenzing-enpoint-messages-v*.csv' \
                     'audit-tenzing-endpoint-agents-v*.csv|audit-tenzing-enpoint-agents-v*.csv'
echo
 
echo "*** Copy AA audit logs ***"
findGenerateAndCopyAuditLogs AA '/var/audit/nuance/automation-adapter /var/log/spinvox/automation-adapter/audit' "~/app_logs/automation-adapter" \
                     audit-automation-adapter-v*.csv
echo
 
 
echo "*** Copy GM audit logs ***"
findGenerateAndCopyAuditLogs GM '/var/audit/nuance/grid-manager /var/log/spinvox/grid-manager/audit' "~/app_logs/grid-manager" \
                     audit-grid-manager-v*.csv
echo
 
 
echo "*** Copy USS audit logs ***"
findGenerateAndCopyAuditLogs USS '/var/log/spinvox/unified-scoring-service/clientLog /var/log/spinvox/unified-scoring-service' "~/app_logs/unified-scoring" \
                     'audit-unified-scoring-scoring-results-v*.csv|ScoringResults*.csv' \
                     'audit-unified-scoring-agents-v*.csv|ReviewerLog*.csv' \
                     'audit-unified-scoring-validation-results-v*.csv|ValidationResults*.csv' \
                     'audit-unified-scoring-detailed-scoring-results-v*.csv|FOM_Detailed_Scoring_Report*.csv' \
                     'audit-unified-scoring-detailed-validation-results-v*.csv|FOM_Detailed_Validation_Report*.csv'
echo
 
echo "*** Copy EJS audit logs ***"
findGenerateAndCopyAuditLogs EJS '/var/audit/nuance/ejector-service /var/log/spinvox/ejector-service/audit' "~/app_logs/ejector" \
                     audit-ejector-service-v*.csv
echo
 
echo "*** Copy PSS audit logs ***"
findGenerateAndCopyAuditLogs PSS '/var/audit/nuance/push-scoring-service /var/log/nuance/push-scoring-service/audit' "~/app_logs/push-scoring" \
                     audit-push-scoring-service-v*.csv \
                     audit-push-scoring-service-detailed-v*.csv
echo

echo "*** Copy E2E PSS audit logs ***"
findGenerateAndCopyAuditLogs "E2E PSS" '/var/audit/nuance/e2e-pss' "~/app_logs/e2e-pss" \
                     audit-ptg-e2e-scoring-service-tx-v*.csv
echo

echo "$TOPIC completed at `date +%T`"
echo

if isEnabled SUCCESS_NOTIFICATION ; then
  if isEnabled SNMP_TRAPS ; then
    sendSnmpTrap $SNMP_INFO "$TOPIC" "`cat $LOG_FILENAME`"
  fi
  if isEnabled EMAIL_NOTIFICATION ; then
    sendEmail "OK" "$TOPIC" "`cat $LOG_FILENAME`"
  fi
fi
