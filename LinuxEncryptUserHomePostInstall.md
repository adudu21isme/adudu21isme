# Tutorial on how to encrypt your Linux /home/user post-install using gocryptfs

gocryptfs: https://github.com/rfjakob/gocryptfs
gocryptfsmanpage: https://github.com/rfjakob/gocryptfs/blob/master/Documentation/MANPAGE.md

This was tested on Linux 6.14.8-1.1-cachyos (Based on Arch Linux) and works on my machine (DE: KDE Plasma 6.3.5, WM: KWin (Wayland))

Since i am using a distro based off arch linux, the commands will be for arch linux.

**david is a placeholder username, you will have to adjust it.**

1. Open Terminal/Konsole or such.

2. Install gocryptfs, if you have not then run `sudo pacman -S gocryptfs`.

3. Once Installed, create another login-able user, you will need this other user (this is to make it more easy).

4. Using your file explorer or such, go to /home/ and find your main user (the user that you did not just create for this).

5. Once you found your main user, create a folder with the name of such user and add "_enc" to the end of it, this is to make it easy to understand  later, example: if user is named "david" then "david_enc".

6. Clone your main user, `sudo cp -a /home/david/.* /home/david_temp/`, 

Once your user is cloned and that all files are in the new folder, delete your old user folder, 

once you deleted your old user folder, create it via mkdir, ensure it is empty and that it will always remain empty (if it is not empty then when using gocryptfs it may error).

7. Okay, we now have a backup of our original user folder, an empty user folder and a user folder that is your main user but ends with `_enc`, run `sudo gocryptfs -init /home/david_enc`, this will ask you to create a password for accessing this that you will have to enter at boot, **DO NOT FORGET IT! SAVE THE BACKUP MASTERKEYS/SUCH IF IT GIVES YOU!**.

8. Great, now we have to add the data of our cloned user back to the main folder but not yet! we have to mount our user, `sudo gocryptfs -allow_other /home/david_enc /home/david`.

9. If it successfully mounted (you put the right password and /home/david is currently empty) then you can now add the data from your cloned user to this one, run `sudo cp -a /home/david_temp/.* /home/david/`.

10. To confirm if data has been successfully saved, unmount /home/david, run `sudo fusermount3 -u /home/david;`, if that fails then run `sudo umount /home/david` and if that still fails then run `sudo umount --lazy /home/david`.

11. Run again, `sudo gocryptfs -allow_other /home/david_enc /home/david`, if the data you added is still there then thats good and we shall continue!

12. Now, we have to make a systemd service, so we have to insert the password at boot to decrypt /home/david_enc (mount /home/david), 

in `/usr/local/bin/`, create a file named `gocryptfsbootunmount.sh` and another one named `gocryptfsbootpassword.sh`, for `gocryptfsbootunmount.sh`, heres the contents:

**This uses placeholder values "david", change it to your user.**
```#!/bin/bash

if ! fusermount3 -u /home/david; then
  echo "fusermount3 failed. Attempting regular umount..."
  if ! umount /home/david; then
    echo "Regular unmount failed. Force unmounting..."
    umount --lazy /home/david
  else
    echo "Successfully unmounted using umount."
  fi
else
  echo "Successfully unmounted using fusermount3."
fi
```

For `gocryptfsbootpassword.sh`:

**This uses placeholder values "david", change it to your user.**
```#!/bin/bash
KEYFILE=$(mktemp /dev/shm/bootdecryptionkey.XXXXXX)
trap 'rm -f "$KEYFILE"' EXIT
echo "Enter Password and then press Enter."
PASSWORD=$(systemd-ask-password "Password")
echo -n "$PASSWORD" > "$KEYFILE"
unset PASSWORD
if gocryptfs -allow_other -passfile "$KEYFILE" /home/david_enc /home/david; then
    chown david:david /home/david
    chmod 700 /home/david
else
    echo "Failed to mount."
    exit 1
fi
```

Now, make a file in `/etc/systemd/system/` named `decrypt-home.service`, contents of `decrypt-home.service`:
```[Unit]
Description=Main User Decrypt
DefaultDependencies=no
After=local-fs.target
Before=basic.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/gocryptfsbootpassword.sh
ExecStop=/usr/local/bin/gocryptfsbootunmount.sh
RemainAfterExit=true
StandardInput=tty
StandardOutput=journal

[Install]
WantedBy=basic.target
```

13. Once we made the required files, 

in terminal/such, run `sudo systemctl daemon-reload` and then run `sudo systemctl enable decrypt-home` which should create a link/such, reboot the system now and enter your correct password, 

if you enter the incorrect password then you will have to go in TTY mode and manually run `sudo gocryptfs -allow_other /home/david_enc /home/david` or reboot and attempt again, 

if systemd is not getting your inputs correctly then press backspace (ensure its empty) and "slowly type" but not too slow, if it still is incorrectly getting your inputs then try a bit slower.

If you ensured your system fully works with gocryptfs then you can delete `/home/david_temp/`, otherwise, if the boot is having errors because of this, enter TTY mode and run `sudo systemctl disable decrypt-home`, you can add the files of `/home/david_temp/` to `/home/david/` and then delete `/home/david_enc/`, remove the systemd service file that we created, remove the files in `/usr/local/bin/` that we created and then reboot.
