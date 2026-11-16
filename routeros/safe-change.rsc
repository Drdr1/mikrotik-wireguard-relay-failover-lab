# Run BEFORE any risky change on the live router. Arms an automatic rollback.
#
#   /import safe-change.rsc      -> backup + export taken, rollback armed for +10 min
#   ...make the change (in Safe Mode: Ctrl+X in the terminal, or the Safe Mode button in Winbox)...
#   /system scheduler remove auto-rollback      -> change confirmed good, cancel rollback
#
# Three layers, so neither of us gets locked out:
#   1. Safe Mode     : if the session drops, everything done in Safe Mode is undone at once.
#   2. auto-rollback : if the change "works" but cuts access, the router loads the
#                      pre-change backup and reboots after 10 minutes unless cancelled.
#   3. pre-change.rsc: plain-text export kept on the router (and copied off it) for manual restore.
# Note: the 10-minute timer is computed from the router clock; don't arm it within
# 10 minutes of midnight.

:local pw "CHANGE-backup-password"
/system backup save name=pre-change password=$pw
/export show-sensitive file=pre-change
:local when ([:totime [/system clock get time]] + 00:10:00)
:do { /system scheduler remove auto-rollback } on-error={}
/system scheduler add name=auto-rollback start-time=$when interval=0 \
    on-event=("/system backup load name=pre-change password=\"" . $pw . "\"") \
    comment="REMOVE after confirming the change"
:put ("rollback armed for " . $when . ". Cancel with: /system scheduler remove auto-rollback")
