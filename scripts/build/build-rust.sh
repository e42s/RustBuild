#!/bin/bash

# I run this in Raspbian chroot with the following command:
#
# $ env -i \
#     HOME=/root \
#     PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
#     SHELL=/bin/bash \
#     TERM=$TERM \
#     chroot /chroot/raspbian/rust /ruststrap/armhf/build-rust.sh

set -x
set -e

: ${CHANNEL:=nightly}
: ${DIST_DIR:=~/dist}
: ${DROPBOX:=~/dropbox_uploader.sh}
: ${MAX_NUMBER_OF_NIGHTLIES:=5}
: ${SNAP_DIR:=/build/snapshot}
: ${SRC_DIR:=/build/rust}

case $CHANNEL in
    beta | stable ) CHANNEL=--release-channel=$CHANNEL;;
    nightly) CHANNEL=;;
    *) echo "unknown release channel: $CHANNEL" && exit 1;;
esac

start=$(date +"%s")

# Update source to upstream
cd $SRC_DIR
git checkout master
git pull

# Optionally checkout older hash
git checkout $1
git submodule update

#Parse the version from the make file
version=$(cat mk/main.mk | grep CFG_RELEASE_NUM | head -n 1 | sed -e "s/.*=//")

# Get the hash and date of the latest snaphot
SNAP_HASH=$(head -n 1 src/snapshots.txt | tr -s ' ' | cut -d ' ' -f 3)

# Check if the snapshot is available
SNAP_TARBALL=$($DROPBOX list snapshots | grep $SNAP_HASH | grep tar)
if [ -z "$SNAP_TARBALL" ]; then
  exit 1
fi
SNAP_TARBALL=$(echo $SNAP_TARBALL | tr -s ' ' | cut -d ' ' -f 3)

# setup snapshot
cd $SNAP_DIR
rm -rf *
$DROPBOX -p download snapshots/$SNAP_TARBALL
tar xjf $SNAP_TARBALL --strip-components=1
rm $SNAP_TARBALL
bin/rustc -V

# Get information about HEAD
cd $SRC_DIR
HEAD_HASH=$(git rev-parse --short HEAD)
HEAD_DATE=$(TZ=UTC date -d @$(git show -s --format=%ct HEAD) +'%Y-%m-%d')
TARBALL=rust-$HEAD_DATE-$HEAD_HASH-arm-unknown-linux-gnueabihf
LOGFILE=rust-$HEAD_DATE-$HEAD_HASH.test.output.txt
LOGFILE_FAILED=rust-$HEAD_DATE-$HEAD_HASH.test.failed.output.txt

# build it
cd build
../configure \
  $CHANNEL \
  --disable-valgrind \
  --enable-ccache \
  --enable-local-rust \
  --enable-llvm-static-stdcpp \
  --local-rust-root=$SNAP_DIR \
  --prefix=/ \
  --build=arm-unknown-linux-gnueabihf \
  --host=arm-unknown-linux-gnueabihf \
  --target=arm-unknown-linux-gnueabihf
make clean
make -j$(nproc)

# package
rm -rf $DIST_DIR/*
DESTDIR=$DIST_DIR make install -j$(nproc)
cd $DIST_DIR
tar czf ~/$TARBALL .
cd ~
TARBALL_HASH=$(sha1sum $TARBALL | tr -s ' ' | cut -d ' ' -f 1)
mv $TARBALL $TARBALL-$TARBALL_HASH.tar.gz
TARBALL=$TARBALL-$TARBALL_HASH.tar.gz

# ship it
if [ -z $DONTSHIP ]; then
  $DROPBOX -p upload $TARBALL .
fi
rm $TARBALL

# delete older nightlies
NUMBER_OF_NIGHTLIES=$($DROPBOX list . | grep rust- | grep tar | wc -l)
for i in $(seq `expr $MAX_NUMBER_OF_NIGHTLIES + 1` $NUMBER_OF_NIGHTLIES); do
  OLDEST_NIGHTLY=$($DROPBOX list . | grep rust- | grep tar | head -n 1 | tr -s ' ' | cut -d ' ' -f 4)
  $DROPBOX delete $OLDEST_NIGHTLY
  OLDEST_TEST_OUTPUT=$(echo $OLDEST_NIGHTLY | cut -d '-' -f 1-5).test.output.txt
  $DROPBOX delete $OLDEST_TEST_OUTPUT || true
  OLDEST_TEST_FAILED_OUTPUT=$(echo $OLDEST_NIGHTLY | cut -d '-' -f 1-5).test.failed.output.txt
  $DROPBOX delete $OLDEST_TEST_FAILED_OUTPUT || true
done

end=$(date +"%s")
diff=$(($end-$start))
echo "Rust Build Time: $(($diff / 3600)) hours, $((($diff / 60) % 60)) minutes and $(($diff % 60)) seconds elapsed."
starttest=$(date +"%s")

# run tests
if [ -z $DONTTEST ]; then
  cd $SRC_DIR/build
  uname -a > $LOGFILE
  echo >> $LOGFILE
  cat $LOGFILE > $LOGFILE_FAILED
  RUST_TEST_THREADS=$(nproc) timeout 7200 make check -k >>$LOGFILE 2>&1 || true
  cat $LOGFILE | grep "FAILED" >> $LOGFILE_FAILED
  $DROPBOX -p upload $LOGFILE .
  $DROPBOX -p upload $LOGFILE_FAILED .
  rm $LOGFILE $LOGFILE_FAILED
fi

# cleanup
rm -rf $DIST_DIR/*
rm -rf $SNAP_DIR/*

end=$(date +"%s")
diff=$(($end-$starttest))
echo "Rust Test Time: $(($diff / 3600)) hours, $((($diff / 60) % 60)) minutes and $(($diff % 60)) seconds elapsed.
diff=$(($end-$start))
echo "Rust Total Time: $(($diff / 3600)) hours, $((($diff / 60) % 60)) minutes and $(($diff % 60)) seconds elapsed.