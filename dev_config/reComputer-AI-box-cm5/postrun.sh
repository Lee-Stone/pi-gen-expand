#!/bin/bash -e
set -x

# Detect if running in chroot environment
IN_CHROOT=0
if [ "$(stat -c %d:%i /)" != "$(stat -c %d:%i /proc/1/root/.)" ]; then
    IN_CHROOT=1
fi

if [ $IN_CHROOT -eq 1 ]; then
    echo "=== Running in chroot: installing hailo-all with postinst fix ==="
    
    # Update and try to install hailo-all (will fail on hailort-pcie-driver)
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y hailo-all 2>&1 | tee /tmp/hailo-install.log || true
    
    # Check if hailort-pcie-driver failed
    if ! dpkg -l hailort-pcie-driver 2>/dev/null | grep -q "^ii"; then
        echo "=== hailort-pcie-driver failed as expected, applying fix ==="
        
        # Check if postinst exists
        if [ -f /var/lib/dpkg/info/hailort-pcie-driver.postinst ]; then
            echo "=== Backing up and modifying postinst ==="
            cp /var/lib/dpkg/info/hailort-pcie-driver.postinst /var/lib/dpkg/info/hailort-pcie-driver.postinst.original
            
            # Create new postinst that detects chroot
            cat > /var/lib/dpkg/info/hailort-pcie-driver.postinst << 'NEWPOSTINST'
#!/bin/bash
set -eEuo pipefail

readonly PKG_NAME="hailort-pcie-driver"
readonly LOG="/var/log/${PKG_NAME}.deb.log"
echo "######### $(date) #########" >> $LOG

# Detect chroot and skip driver operations
if [ "$(stat -c %d:%i /)" != "$(stat -c %d:%i /proc/1/root/.)" ]; then
    echo "=== Detected chroot environment ===" | tee -a $LOG
    echo "Skipping driver compilation and module loading" | tee -a $LOG
    echo "Driver will be functional after first boot" | tee -a $LOG
    exit 0
fi

# Original postinst for real hardware
NEWPOSTINST
            
            # Append original content (skip first 3 lines: shebang, blank, set -e)
            tail -n +4 /var/lib/dpkg/info/hailort-pcie-driver.postinst.original >> /var/lib/dpkg/info/hailort-pcie-driver.postinst
            chmod 755 /var/lib/dpkg/info/hailort-pcie-driver.postinst
            
            echo "=== Reconfiguring hailort-pcie-driver ==="
            dpkg --configure hailort-pcie-driver
            
            echo "=== Reconfiguring all packages ==="
            dpkg --configure -a
            
            echo "=== Verification ==="
            dpkg -l | grep hailort-pcie-driver
            dpkg -l | grep hailo-all
        else
            echo "ERROR: postinst file not found!"
            exit 1
        fi
    else
        echo "=== hailort-pcie-driver already configured ==="
    fi
    
    echo "=== hailo-all installation completed ==="
else
    echo "=== Running on real hardware: standard installation ==="
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y hailo-all
fi

arch_r=$(dpkg --print-architecture)
BOOKWORM_NUM=12
DEBIAN_VER=`cat /etc/debian_version`
DEBIAN_NUM=$(echo "$DEBIAN_VER" | awk -F'.' '{print $1}')

_VER_RUN=""
function get_kernel_version() {
  local ZIMAGE IMG_OFFSET

  if [ -z "$_VER_RUN" ]; then
    if [ $DEBIAN_NUM -lt $BOOKWORM_NUM ]; then
      ZIMAGE=/boot/kernel7l.img
      if [ $arch_r == "arm64" ]; then
        ZIMAGE=/boot/kernel8.img
      fi
    else
      ZIMAGE=/boot/firmware/kernel7l.img
      if [[ $arch_r == "arm64" || $uname_r == *rpi-v8* ]]; then
        ZIMAGE=/boot/firmware/kernel8.img
        # if is pi5 or cm5, we use kernel_2712.img, if rpi-2712 in uname_r
        if [[ $uname_r == *2712* ]]; then
          ZIMAGE=/boot/firmware/kernel_2712.img
        fi
      fi
    fi
  fi

  [ -f /boot/firmware/vmlinuz ] && ZIMAGE=/boot/firmware/vmlinuz
  IMG_OFFSET=$(LC_ALL=C grep -abo $'\x1f\x8b\x08\x00' $ZIMAGE | head -n 1 | cut -d ':' -f 1)
  _VER_RUN=$(dd if=$ZIMAGE obs=64K ibs=4 skip=$(( IMG_OFFSET / 4)) 2>/dev/null | zcat | grep -a -m1 "Linux version" | strings | awk '{ print $3; }' | grep "[0-9]")

  echo "$_VER_RUN"
  
  return 0
}

kernelver=$(get_kernel_version)

VERSION=$(apt list hailo-all | grep hailo-all | awk '{print $2}' | cut -d' ' -f1)
git clone https://github.com/hailo-ai/hailort-drivers.git -b v$VERSION hailort-drivers
cd hailort-drivers/linux/pcie

make all kernelver=$kernelver

cd ../..

if [ -f "./download_firmware.sh" ]; then
    chmod +x ./download_firmware.sh
    ./download_firmware.sh
    mkdir -p /lib/firmware/hailo
    mv hailo8_fw.4.*.bin /lib/firmware/hailo/hailo8_fw.bin
else
    echo "Warning: download_firmware.sh not found, skipping firmware installation"
fi

mkdir -p /etc/udev/rules.d
cp ./linux/pcie/51-hailo-udev.rules /etc/udev/rules.d/

rm -rf hailort-drivers

# install examples
echo ${FIRST_USER_NAME}
sudo echo ${FIRST_USER_NAME}

cd /home/${FIRST_USER_NAME}
pwd
uname -a
git clone https://github.com/hailo-ai/hailo-rpi5-examples.git
cd hailo-rpi5-examples
sed -i 's/device_arch=.*$/device_arch=HAILO8/g' setup_env.sh
sed -i '/sudo apt install python3-gi python3-gi-cairo/ s/$/ -y/' install.sh
./install.sh || true

free -h
swapon --show
df -h

# clean temp files and caches
apt-get -y autoremove --purge
apt-get -y clean
rm -rf /tmp/*