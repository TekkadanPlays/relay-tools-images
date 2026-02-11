# machines

In this folder are scripts to build nspawn images for the various components of relay-tools.

## base image

In the root there is a `build`, `clean` and `console`. 

- `build` creates a debian rootfs with Go installed that is used by the images in the subfolders.
- `clean` clears all of the rootfs and calls the clean functions of all the others' clean functions.
- `console` boots the base debian image and drops you in a shell.

Note that all `console` scripts provide a password for root to login, which is created in the install process, including the base `build` script, for the base debian image.

## subfolders/nspawn images

Within the subfolders `haproxy`, `mysql`, `relaycreator`, `strfry` and `keys-certs-manager` there is a common set of functions whose choice of names for the nspawn images is based on the directory name. These contain the following common scripts/functions:

- `clean` - deletes the image and all the deployment related files in `/etc/systemd/nspawn` and `/var/lib/machines`. generally these do not touch any bind mount folders.
- `console` - starts up the nspawn machine using `machinectl` and logs you in to it. the password the `install` script defines is printed prior to the login so you can c&p it after typing `root` into the user prompt.
- `start` - just starts up the nspawn image. requires that it exist, of course.
- `status` - calls `machinectl status <imagename>` which probably will open with a pager. Of course to see all currently running images `machinectl list`.
- `stop` - stops the nspawn image. will print nothing if it doesn't exist

# install

in each subfolder there is a script called `install`. 

this script has common elements where it determines the script location in order to place a password file in the `machines` directory, where `console` will look for it, and the script takes note of its filesystem path, which is used to find any relevant things other than this, and derives the image name from the directory name so as to not have this need to be explicitly defined and fall victim to bitrot.

each script tries to create relevant folders in `/var/lib/machines` and copies the `nspawn` file to `<appname>.nspawn` in `/etc/systemd/nspawn/`.

after the preparatory work, each script has an inline script within an EOF block that runs the deployment installation.

## example

```
cd relay-tools-images/machines
# installs prereqs for systemd-nspawn
./prereqs.sh
# builds all the images
./build
# first: setup DNS to point at this server's IP address
# set the environment variable to your DNS
export MYDOMAIN=example.com
# optional: set email for Let's Encrypt expiry notifications
export MYEMAIL=you@example.com
./configure.sh
# enable all machines to start on boot
machinectl enable mysql && machinectl enable strfry && machinectl enable relaycreator && machinectl enable haproxy
```

## todo

- [x] implement certificate and keys automatic config/rotation
- [x] fix bundle.pem path mismatch in configure.sh
- [x] fix missing haproxy bind mount for /srv/relaycreator
- [x] add keys-certs-manager to build script
- [x] add mysql wait timeout in configure.sh
- [x] upgrade Node.js 18 to 20, pin pnpm to v9
- [x] add .gitattributes for LF line endings
- [x] set executable permissions on all scripts
