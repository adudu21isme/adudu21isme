#!/bin/bash
set -euo pipefail
USER="${USER:-$(id -un)}"

# rm_report <label> <path...>: removes paths and reports whether anything was found
rm_report() {
  local label="$1" p hit=0
  shift
  for p in "$@"; do
    if [[ -e "$p" || -L "$p" ]]; then
      rm -rf "$p"
      hit=1
    fi
  done
  if (( hit )); then
    echo "$label: deleted"
  else
    echo "$label: not found, nothing deleted"
  fi
}

# nullify <path>: replaces a path with a symlink to /dev/null and reports what happened
nullify() {
  local p="$1"
  if [[ ! -d "$(dirname "$p")" ]]; then
    echo "$p: parent folder not found, skipped"
    return 0
  fi
  if [[ -L "$p" && "$(readlink "$p")" == "/dev/null" ]]; then
    echo "$p: already null, not modified"
    return 0
  fi
  if [[ -e "$p" || -L "$p" ]]; then
    rm -rf "$p"
    echo "$p: deleted, replaced with null link"
  else
    echo "$p: not found, created null link"
  fi
  ln -s /dev/null "$p"
}

running=$(flatpak ps --columns=application 2>/dev/null || true)
if grep -qE 'org\.vinegarhq\.(Vinegar|Sober)' <<<"$running"; then
  echo "Close Studio/Sober first. Don't open them while this script is active."
  exit 1
fi

# strip_referents <dir> <label>: removes referent="..." from Global*Settings*.xml and reports what happened
strip_referents() {
  local dir="$1" label="$2" f found=0
  if [[ ! -d "$dir" ]]; then
    echo "$label: folder not found, nothing modified"
    return 0
  fi
  while IFS= read -r -d '' f; do
    found=1
    if grep -q ' referent="' "$f"; then
      sed -i 's/ referent="[^"]*"//g' "$f"
      echo "$label: modified $(basename "$f")"
    else
      echo "$label: $(basename "$f") already clean, not modified"
    fi
  done < <(find "$dir" -name 'Global*Settings*.xml' -print0)
  if (( found == 0 )); then
    echo "$label: no Global*Settings*.xml found, nothing modified"
  fi
}

echo "Client/Studio remove some stuff"
base="$HOME/.var/app"
vinegar="$base/org.vinegarhq.Vinegar"
vinegarData="$vinegar/data/vinegar"
sober="$base/org.vinegarhq.Sober"

# detect that Studio is installed (any version folder containing the exe)
studio_path=""
for f in "$vinegarData"/versions/version-*/RobloxStudioBeta.exe; do
  [[ -f "$f" ]] && { studio_path="$f"; break; }
done
unset f

dirs=(
  rbx-storage
  AnalysticsSettings.xml
  frm.cfg
  rbx-storage.db
  rbx-storage.db-shm
  rbx-storage.db-wal
  rbx-storage.id
)

# ---------------- Sober (client) ----------------
if [[ -d "$sober" ]]; then
  soberData="$sober/data/sober"
  soberAppData="$soberData/appData"
  rm_report "Sober pulse cookie" "$sober/config/pulse/cookie"
  read -rp "Delete all Sober cache? [y/n]: " c
  if [[ "${c,,}" == "y" ]]; then
    rm_report "Sober cache" "$sober/cache"
  fi
  rm_report "Sober logs" "$soberData/sober_logs"
  rm_report "Sober crash logs" "$soberData/crashes"
  read -rp "Delete Sober cookies? [y/n]: " ck
  if [[ "${ck,,}" == "y" ]]; then
    rm_report "Sober cookies, LocalStorage and sober_services" \
      "$soberData/cookies" "$soberAppData/LocalStorage" "$sober/data/sober_services"
  fi
  rm_report "Sober OTAPatchBackups" "$soberAppData/OTAPatchBackups"
  for d in "${dirs[@]}"; do nullify "$soberAppData/$d"; done
  rm_report "Sober app logs" "$soberAppData/logs"
  strip_referents "$soberAppData" "Sober"
  unset c ck d soberData soberAppData
  echo "Done with Client"
fi
unset sober

# ---------------- Studio (Vinegar) ----------------
if [[ -f "$studio_path" ]]; then
  rm_report "Vinegar pulse cookie" "$vinegar/config/pulse/cookie"
  drive_c="$vinegarData/prefixes/studio/drive_c"
  studio_prefix="$vinegarData/appdata/Roblox"
  read -rp "Delete Vinegar cache? [y/n]: " vc
  if [[ "${vc,,}" == "y" ]]; then
    rm_report "Roblox temp" \
      "$drive_c/users/$USER/AppData/Local/Temp/Roblox" "$drive_c/windows/temp/Roblox"
  fi
  rm_report "Vinegar logs" "$vinegar/cache/vinegar/logs"
  rm_report "Datadog Tracer logs" "$drive_c/ProgramData/Datadog Tracer/logs"
  for d in "$studio_prefix"/[0-9]*; do
    [[ -d "$d" ]] || continue
    read -rp "Delete user plugin folder $(basename "$d")? [y/n]: " r
    if [[ "${r,,}" == "y" ]]; then
      rm_report "Plugin folder $(basename "$d")" "$d"
    fi
  done
  rm_report "Studio logs and misc data" \
    "$studio_prefix"/{logs,OTAPatchBackups,LocalStorage,placeIDEState,RobloxStudio,UserCaptures,AssistantSettings}
  for d in "${dirs[@]}"; do nullify "$studio_prefix/$d"; done
  strip_referents "$studio_prefix" "Studio"
  read -rp "Fix LocalAssetsFolder? [y/n]: " la
  if [[ "${la,,}" == "y" ]]; then
    shopt -s nullglob
    settings_files=("$studio_prefix"/GlobalSettings_*.xml)
    shopt -u nullglob
    if (( ${#settings_files[@]} == 0 )); then
      echo "LocalAssetsFolder: no GlobalSettings_*.xml found, nothing modified"
    fi
    for f in "${settings_files[@]}"; do
      if grep -q 'name="LocalAssetsFolder"' "$f"; then
        sed -i "s|<QDir name=\"LocalAssetsFolder\">[^<]*</QDir>|<QDir name=\"LocalAssetsFolder\">C:/users/$USER/AppData/Local/Roblox/LocalAssets</QDir>|" "$f"
        echo "LocalAssetsFolder: modified $(basename "$f")"
      else
        echo "LocalAssetsFolder: no entry in $(basename "$f"), not modified"
      fi
    done
    unset settings_files f
  fi
  echo "Done with Studio Files, moving to Registry..."
  unset vc d r la drive_c studio_prefix
fi
unset dirs

# clean_reg <reg_file> <wine|regedit> <label>
# "common" trackers are always stripped once the user opts to modify the
# file; "fullonly" entries (saved auth + the WebView2 login profile data)
# are only stripped when the user asks to erase everything.
clean_reg() {
  local reg_file="$1" style="$2" label="$3"
  if [[ ! -f "$reg_file" ]]; then
    echo "$label: not found, skipped"
    return 0
  fi
  read -rp "Modify $label? (contains logins and some trackers you likely want to remove) [y/n]: " clean
  if [[ "${clean,,}" != "y" ]]; then
    return 0
  fi
  local reg_bak="$reg_file.bak"
  if [[ -f "$reg_bak" ]]; then
    read -rp "Restore $label from backup? [y/n]: " restore
    if [[ "${restore,,}" == "y" ]]; then
      cp "$reg_bak" "$reg_file"
      rm -f "$reg_bak"
      echo "Restored $label. Done!"
      return 0
    fi
    echo "Keeping existing backup for $label untouched."
  else
    read -rp "Backup $label? [y/n]: " bkup
    if [[ "${bkup,,}" == "y" ]]; then
      cp "$reg_file" "$reg_bak"
      echo "Backed up $label"
    fi
  fi
  read -rp "Erase all User Information or only Trackers? [y/n]: " full
  local deleteFull=0
  [[ "${full,,}" == "y" ]] && deleteFull=1
  local tmpfile
  tmpfile=$(mktemp "$reg_file.XXXXXX")
  if [[ "$style" == "wine" ]]; then
    awk -v deleteFull="$deleteFull" '
      BEGIN { skip = 0 }
      /^"File_Sync_Persistence_Record_V1:/ { next }
      /^[[][^]]*[]]/ {
        hdr = $0
        common = (hdr ~ /^\[Software\\\\Roblox\\\\Retention\]/ ||
                  hdr ~ /^\[Software\\\\Roblox\\\\RobloxStudio\\\\RobloxStudioFirstTimeLoggedIn\\\\https:\\\\www\.roblox\.com\]/ ||
                  hdr ~ /^\[Software\\\\Roblox\\\\RobloxStudio\\\\RobloxStudioLaunchTrackingGuid\\\\https:\\\\www\.roblox\.com\]/ ||
                  hdr ~ /^\[Software\\\\Roblox\\\\RobloxStudio\\\\RobloxStudioMostRecentLogin\\\\https:\\\\www\.roblox\.com\]/ ||
                  hdr ~ /NewUserExperiment/ ||
                  hdr ~ /rbxRecentFiles/ ||
                  hdr ~ /LoggedInUsersStore/ ||
                  hdr ~ /rbxRecentRobloxApiGames/ ||
                  hdr ~ /File_Sync_Persistence_Record_V1:/ ||
                  hdr ~ /RibbonNotificationStoreRootKey-/ ||
                  hdr ~ /AssistantMetadata/)
        fullonly = (hdr ~ /^\[Software\\\\Wine\\\\Credential Manager\\\\Generic: https:\/\/www\.roblox\.com:RobloxStudioAuth.*\]/ ||
                    hdr ~ /^\[Software\\\\Microsoft\\\\EdgeWebView/)
        skip = (common || (deleteFull == 1 && fullonly))
        if (skip) next
        print hdr
        next
      }
      skip { next }
      { print }
    ' "$reg_file" > "$tmpfile" || { rm -f "$tmpfile"; echo "$label: awk failed, not modified"; return 0; }
  else
    awk -v deleteFull="$deleteFull" '
      BEGIN { skip = 0 }
      /^"File_Sync_Persistence_Record_V1:/ { next }
      /^[[][^]]*[]]/ {
        hdr = $0
        common = (hdr ~ /^\[HKEY_CURRENT_USER\\Software\\Roblox\\Retention\]/ ||
                  hdr ~ /^\[HKEY_CURRENT_USER\\Software\\Roblox\\RobloxStudio\\RobloxStudioFirstTimeLoggedIn\\https:\\www\.roblox\.com\]/ ||
                  hdr ~ /^\[HKEY_CURRENT_USER\\Software\\Roblox\\RobloxStudio\\RobloxStudioLaunchTrackingGuid\\https:\\www\.roblox\.com\]/ ||
                  hdr ~ /^\[HKEY_CURRENT_USER\\Software\\Roblox\\RobloxStudio\\RobloxStudioMostRecentLogin\\https:\\www\.roblox\.com\]/ ||
                  hdr ~ /NewUserExperiment/ ||
                  hdr ~ /rbxRecentFiles/ ||
                  hdr ~ /LoggedInUsersStore/ ||
                  hdr ~ /rbxRecentRobloxApiGames/ ||
                  hdr ~ /File_Sync_Persistence_Record_V1:/ ||
                  hdr ~ /RibbonNotificationStoreRootKey-/ ||
                  hdr ~ /AssistantMetadata/)
        fullonly = (hdr ~ /^\[HKEY_CURRENT_USER\\Software\\Wine\\Credential Manager\\Generic: https:\/\/www\.roblox\.com:RobloxStudioAuth.*\]/ ||
                    hdr ~ /^\[HKEY_CURRENT_USER\\Software\\Microsoft\\EdgeWebView/)
        skip = (common || (deleteFull == 1 && fullonly))
        if (skip) next
        print hdr
        next
      }
      skip { next }
      { print }
    ' "$reg_file" > "$tmpfile" || { rm -f "$tmpfile"; echo "$label: awk failed, not modified"; return 0; }
  fi
  if cmp -s "$reg_file" "$tmpfile"; then
    rm -f "$tmpfile"
    echo "$label: nothing to remove, not modified"
  else
    chmod --reference="$reg_file" "$tmpfile"
    mv "$tmpfile" "$reg_file"
    echo "$label: modified"
  fi
}

user_reg="$vinegarData/prefixes/studio/user.reg"
settings_reg="$vinegarData/settings.reg"
unset vinegarData
clean_reg "$user_reg" "wine" "user.reg"
clean_reg "$settings_reg" "regedit" "settings.reg"
unset user_reg settings_reg

echo "Done!"
exit 0
