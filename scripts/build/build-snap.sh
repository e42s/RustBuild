#!/usr/bin/env bash

# I run this in Debian Jessie container with the following command:
#
# $ env -i \
#     HOME=/root \
#     PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
#     SHELL=/bin/bash \
#     TERM=$TERM \
#     systemd-nspawn /chroot/RustBuild/ /bin/bash ~/build-snap.sh

set -x
set -e

: ${CHANNEL:=nightly}
: ${BRANCH:=master}
: ${DROPBOX:=~/dropbox_uploader.sh}
: ${SNAP_DIR:=/build/snapshot}
: ${SRC_DIR:=/build/rust}
# Determines if we can't get the second to last snapshot, if we should try with
# the oldest, or just fail.
: ${FAIL_TO_OLDEST_SNAP:=true}
# The number of process we should use while building
: ${BUILD_PROCS:=$(($(nproc)-1))}

# Set the build procs to 1 less than the number of cores/processors available,
# but always atleast 1 if there's only one processor/core
if [ ! $BUILD_PROCS -gt 1 ]; then BUILD_PROCS=1; fi

# Set the channel
if [ ! -z $1 ]; then
  CHANNEL=$1
fi

# Configure the build
case $CHANNEL in
  stable)
    BRANCH=stable
  ;;
  beta)
    BRANCH=beta
  ;;
  nightly);;
  tag-*)
    # Allow custom branches to be requested
    BRANCH=$(echo $CHANNEL | $(sed 's/tag-//') .
  ;;
  *) 
    echo "unknown release channel: $CHANNEL" && exit 1
  ;;
esac

start=$(date +"%s")

# checkout latest rust $BRANCH
cd $SRC_DIR
git checkout $BRANCH
git pull
git submodule update

# check if the latest snapshot has already been built
LAST_SNAP_HASH=$(head src/snapshots.txt | head -n 1 | tr -s ' ' | cut -d ' ' -f 3)
if [ ! -z "$($DROPBOX list snapshots | grep $LAST_SNAP_HASH)" ]; then
  # already there, nothing left to do
  echo "Latest snapshot already exists: $LAST_SNAP_HASH"
  exit 0
fi

#This is the second to last snapshot. This is the snapshot that should be used to build the next one
SECOND_TO_LAST_SNAP_HASH=$(cat src/snapshots.txt | grep "S " | sed -n 2p | tr -s ' ' | cut -d ' ' -f 3)
if [ -z "$($DROPBOX list snapshots | grep $SECOND_TO_LAST_SNAP_HASH)" ]; then
  if [ $FAIL_TO_OLDEST_SNAP -eq "true" ]; then
    snap_count=$(cat src/snapshots.txt | grep "S " | wc -l)
    for pos in 'seq 3 $snap_count'; do
      SECOND_TO_LAST_SNAP_HASH=$(cat src/snapshots.txt | grep "S " | sed -n ${pos}p | tr -s ' ' | cut -d ' ' -f 3)
      if [ -z "$($DROPBOX list snapshots | grep $SECOND_TO_LAST_SNAP_HASH)" ]; then
        if [ $pos -eq $snap_count ]; then
          echo "No snapshot older than  ${LAST_SNAP_HASH} available. Need an older snapshot to build a current snapshot"
          exit 1
        else
          continue
        fi
      fi
    done
  else
    # not here, we need this snapshot to continue
    echo "Need snapshot ${SECOND_TO_LAST_SNAP_HASH} to compile snapshot compiler ${LAST_SNAP_HASH}"
    exit 1
  fi
fi

# Use the second to last snapshot to build the next snapshot
# setup snapshot
cd $SNAP_DIR
# Only need to download if our current snapshot is not at the right version
INSTALLED_SNAPSHOT_VERSION=
if [ -f VERSION ]; then
  INSTALLED_SNAPSHOT_VERSION=$(cat VERSION)
fi
if [ "$SNAP_TARBALL" != "$INSTALLED_SNAPSHOT_VERSION" ]; then
  rm -rf *
  SNAP_TARBALL=$($DROPBOX list snapshots | grep ${SECOND_TO_LAST_SNAP_HASH}- | tr -s ' ' | cut -d ' ' -f 4)
  $DROPBOX -p download snapshots/$SNAP_TARBALL
  tar xjf $SNAP_TARBALL --strip-components=1
  rm $SNAP_TARBALL
  echo "$SNAP_TARBALL" > VERSION
else
  echo "Requested snapshot $SNAP_TARBALL already installed, no need to re-download and install."
fi

# build it
cd $SRC_DIR
git checkout $LAST_SNAP_HASH
cd build
../configure \
  --disable-docs \
  --disable-valgrind \
  --enable-ccache \
  --enable-clang \
  --disable-libcpp \
  --enable-local-rust \
  --enable-llvm-static-stdcpp \
  --local-rust-root=$SNAP_DIR \
  --prefix=/ \
  --build=arm-unknown-linux-gnueabihf \
  --host=arm-unknown-linux-gnueabihf \
  --target=arm-unknown-linux-gnueabihf
make clean
make -j $BUILD_PROCS
make -j $BUILD_PROCS snap-stage3-H-arm-unknown-linux-gnueabihf

# ship it
$DROPBOX -p upload rust-stage0-* snapshots
rm rust-stage0-*

# cleanup
#rm -rf $SNAP_DIR/*

end=$(date +"%s")
diff=$(($end-$start))
echo "Rust Snapshot Total Time: $(($diff / 3600)) hours, $((($diff / 60) % 60)) minutes and $(($diff % 60)) seconds elapsed."
