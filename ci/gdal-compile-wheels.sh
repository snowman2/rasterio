# INSTALL PROJ & DEPENDENCIES FOR WHEELS
# Test for macOS with [ -n "$IS_MACOS" ]
LIBPNG_VERSION=1.6.35
ZLIB_VERSION=1.2.11
LIBDEFLATE_VERSION=1.7
JPEG_VERSION=9f
LIBWEBP_VERSION=1.3.2
OPENJPEG_VERSION=2.4.0
GEOS_VERSION=3.11.1
JSONC_VERSION=0.15
SQLITE_VERSION=3330000
PROJ_VERSION=9.3.1
GDAL_VERSION=3.9.1
CURL_VERSION=8.8.0
NGHTTP2_VERSION=1.46.0
EXPAT_VERSION=2.2.6
HDF5_VERSION=1.12.1
NETCDF_VERSION=4.6.2
ZSTD_VERSION=1.5.0
TIFF_VERSION=4.3.0
LERC_VERSION=4.0.0
XZ_VERSION=5.8.0
BLOSC_VERSION=1.10.2
GIFLIB_VERSION=5.1.3
OPENSSL_DOWNLOAD_URL=https://www.openssl.org/source/
OPENSSL_ROOT=openssl-1.1.1w
OPENSSL_HASH=cf3098950cb4d853ad95c0841f1f9c6d3dc102dccfcacd521d93925208b76ac8
PCRE_VERSION=10.44


# ------------------------------------------
# From: https://github.com/multi-build/multibuild/
# ------------------------------------------
BUILD_PREFIX="${BUILD_PREFIX:-/usr/local}"
OPENSSL_ROOT=${OPENSSL_ROOT:-openssl-3.2.1}
# Hash from https://www.openssl.org/source/openssl-3.2.1.tar.gz.sha256
OPENSSL_HASH=${OPENSSL_HASH:-6ae015467dabf0469b139ada93319327be24b98251ffaeceda0221848dc09262}
OPENSSL_DOWNLOAD_URL=${OPENSSL_DOWNLOAD_URL:-https://www.openssl.org/source}

if [ $(uname) == "Darwin" ]; then
  IS_MACOS=1;
fi

if [ -f /etc/alpine-release ]; then
  IS_ALPINE=1
fi

if [ -z "$IS_MACOS" ]; then
    # Strip all binaries after compilation.
    STRIP_FLAGS=${STRIP_FLAGS:-"-Wl,-strip-all"}

    export CFLAGS="${CFLAGS:-$STRIP_FLAGS}"
    export CXXFLAGS="${CXXFLAGS:-$STRIP_FLAGS}"
    export FFLAGS="${FFLAGS:-$STRIP_FLAGS}"
fi

export CPPFLAGS_BACKUP="$CPPFLAGS"
export LIBRARY_PATH_BACKUP="$LIBRARY_PATH"
export PKG_CONFIG_PATH_BACKUP="$PKG_CONFIG_PATH"

function update_env_for_build_prefix {
  # Promote BUILD_PREFIX on search path to any newly built libs
  export CPPFLAGS="-I$BUILD_PREFIX/include $CPPFLAGS_BACKUP"
  export LIBRARY_PATH="$BUILD_PREFIX/lib:$LIBRARY_PATH_BACKUP"
  export PKG_CONFIG_PATH="$BUILD_PREFIX/lib/pkgconfig/:$PKG_CONFIG_PATH_BACKUP"
  # Add binary path for configure utils etc
  export PATH="$BUILD_PREFIX/bin:$PATH"
}

function rm_mkdir {
    # Remove directory if present, then make directory
    local path=$1
    if [ -z "$path" ]; then echo "Need not-empty path"; exit 1; fi
    if [ -d "$path" ]; then rm -rf $path; fi
    mkdir $path
}

function untar {
    local in_fname=$1
    if [ -z "$in_fname" ];then echo "in_fname not defined"; exit 1; fi
    local extension=${in_fname##*.}
    case $extension in
        tar) tar -xf $in_fname ;;
        gz|tgz) tar -zxf $in_fname ;;
        bz2) tar -jxf $in_fname ;;
        zip) unzip -qq $in_fname ;;
        xz) if [ -n "$IS_MACOS" ]; then
              tar -xf $in_fname
            else
              if [[ ! $(type -P "unxz") ]]; then
                echo xz must be installed to uncompress file; exit 1
              fi
              unxz -c $in_fname | tar -xf -
            fi ;;
        *) echo Did not recognize extension $extension; exit 1 ;;
    esac
}

function suppress {
    # Run a command, show output only if return code not 0.
    # Takes into account state of -e option.
    # Compare
    # https://unix.stackexchange.com/questions/256120/how-can-i-suppress-output-only-if-the-command-succeeds#256122
    # Set -e stuff agonized over in
    # https://unix.stackexchange.com/questions/296526/set-e-in-a-subshell
    local tmp=$(mktemp tmp.XXXXXXXXX) || return
    local errexit_set
    echo "Running $@"
    if [[ $- = *e* ]]; then errexit_set=true; fi
    set +e
    ( if [[ -n $errexit_set ]]; then set -e; fi; "$@"  > "$tmp" 2>&1 ) ; ret=$?
    [ "$ret" -eq 0 ] || cat "$tmp"
    rm -f "$tmp"
    if [[ -n $errexit_set ]]; then set -e; fi
    return "$ret"
}

function yum_install {
    # CentOS 5 yum doesn't fail in some cases, e.g. if package is not found
    # https://serverfault.com/questions/694942/yum-should-error-when-a-package-is-not-available
    yum install -y "$1" && rpm -q "$1"
}

function install_rsync {
    # install rsync via package manager
    if [ -n "$IS_MACOS" ]; then
        # macOS. The colon in the next line is the null command
        :
    elif [ -n "$IS_ALPINE" ]; then
        [[ $(type -P rsync) ]] || apk add rsync
    elif [[ $MB_ML_VER == "_2_24" ]]; then
        # debian:9 based distro
        [[ $(type -P rsync) ]] || apt-get install -y rsync
    else
        # centos based distro
        [[ $(type -P rsync) ]] || yum_install rsync
    fi
}

function fetch_unpack {
    # Fetch input archive name from input URL
    # Parameters
    #    url - URL from which to fetch archive
    #    archive_fname (optional) archive name
    #
    # Echos unpacked directory and file names.
    #
    # If `archive_fname` not specified then use basename from `url`
    # If `archive_fname` already present at download location, use that instead.
    local url=$1
    if [ -z "$url" ];then echo "url not defined"; exit 1; fi
    local archive_fname=${2:-$(basename $url)}
    local arch_sdir="${ARCHIVE_SDIR:-archives}"
    if [ -z "$IS_MACOS" ]; then
        local extension=${archive_fname##*.}
        if [ "$extension" == "xz" ]; then
            ensure_xz
        fi
    fi
    # Make the archive directory in case it doesn't exist
    mkdir -p $arch_sdir
    local out_archive="${arch_sdir}/${archive_fname}"
    # If the archive is not already in the archives directory, get it.
    if [ ! -f "$out_archive" ]; then
        # Source it from multibuild archives if available.
        local our_archive="${MULTIBUILD_DIR}/archives/${archive_fname}"
        if [ -f "$our_archive" ]; then
            ln -s $our_archive $out_archive
        else
            # Otherwise download it.
            curl -L $url > $out_archive
        fi
    fi
    # Unpack archive, refreshing contents, echoing dir and file
    # names.
    rm_mkdir arch_tmp
    install_rsync
    (cd arch_tmp && \
        untar ../$out_archive && \
        ls -1d * &&
        rsync --delete -ah * ..)
}

function build_simple {
    # Example: build_simple libpng $LIBPNG_VERSION \
    #               https://download.sourceforge.net/libpng tar.gz \
    #               --additional --configure --arguments
    local name=$1
    local version=$2
    local url=$3
    local ext=${4:-tar.gz}
    local configure_args=${@:5}
    if [ -e "${name}-stamp" ]; then
        return
    fi
    local name_version="${name}-${version}"
    local archive=${name_version}.${ext}
    fetch_unpack $url/$archive
    (cd $name_version \
        && ./configure --prefix=$BUILD_PREFIX $configure_args \
        && make -j4 \
        && make install)
    touch "${name}-stamp"
}

function get_modern_cmake {
    # Install cmake >= 2.8
    if [ -n "$IS_ALPINE" ]; then return; fi  # alpine has modern cmake already
    local cmake=cmake
    if [ -n "$IS_MACOS" ]; then
        brew install cmake > /dev/null
    elif [[ $MB_ML_VER == "_2_24" ]]; then
        # debian:9 based distro
        apt-get install -y cmake
    else
        if [ "`yum search cmake | grep ^cmake28\.`" ]; then
            cmake=cmake28
        fi
        # centos based distro
        yum_install $cmake > /dev/null
    fi
    echo $cmake
}

function build_zlib {
    # Gives an old but safe version
    if [ -n "$IS_MACOS" ]; then return; fi  # OSX has zlib already
    if [ -n "$IS_ALPINE" ]; then return; fi  # alpine has zlib already
    if [ -e zlib-stamp ]; then return; fi
    if [[ $MB_ML_VER == "_2_24" ]]; then
        # debian:9 based distro
        apt-get install -y zlib1g-dev
    else
        #centos based distro
        yum_install zlib-devel
    fi
    touch zlib-stamp
}

function build_perl {
    if [ -n "$IS_MACOS" ]; then return; fi  # OSX has perl already
    if [ -n "$IS_ALPINE" ]; then return; fi  # alpine has perl already
    if [ -e perl-stamp ]; then return; fi
    if [[ $MB_ML_VER == "_2_24" ]]; then
        # debian:9 based distro
        apt-get install -y perl
    else
        # centos based distro
        yum_install perl-core
    fi
    touch perl-stamp
}


function build_openssl {
    if [ -e openssl-stamp ]; then return; fi
    suppress build_perl
    fetch_unpack ${OPENSSL_DOWNLOAD_URL}/${OPENSSL_ROOT}.tar.gz
    check_sha256sum $ARCHIVE_SDIR/${OPENSSL_ROOT}.tar.gz ${OPENSSL_HASH}
    (cd ${OPENSSL_ROOT} \
        && ./config no-ssl2 no-shared -fPIC --prefix=$BUILD_PREFIX \
        && make -j4 \
        && make install)
    touch openssl-stamp
}

function build_giflib {
    local name=giflib
    local version=$GIFLIB_VERSION
    local url=https://downloads.sourceforge.net/project/giflib
    if [ $(lex_ver $GIFLIB_VERSION) -lt $(lex_ver 5.1.5) ]; then
        build_simple $name $version $url
    else
        local ext=tar.gz
        if [ -e "${name}-stamp" ]; then
            return
        fi
        local name_version="${name}-${version}"
        local archive=${name_version}.${ext}
        fetch_unpack $url/$archive
        (cd $name_version \
            && make -j4 \
            && make install PREFIX=$BUILD_PREFIX)
        touch "${name}-stamp"
    fi
}

function build_xz {
    build_simple xz $XZ_VERSION https://github.com/tukaani-project/xz/releases/download/v$XZ_VERSION
}

function build_libpng {
    suppress build_zlib
    build_simple libpng $LIBPNG_VERSION https://download.sourceforge.net/libpng
}

function build_jpeg {
    if [ -e jpeg-stamp ]; then return; fi
    fetch_unpack http://ijg.org/files/jpegsrc.v${JPEG_VERSION}.tar.gz
    (cd jpeg-${JPEG_VERSION} \
        && ./configure --prefix=$BUILD_PREFIX $HOST_CONFIGURE_FLAGS \
        && make -j4 \
        && make install)
    touch jpeg-stamp
}

function build_netcdf {
    if [ -e netcdf-stamp ]; then return; fi
    suppress build_hdf5
    suppress build_curl_ssl
    fetch_unpack https://github.com/Unidata/netcdf-c/archive/v${NETCDF_VERSION}.tar.gz
    (cd netcdf-c-${NETCDF_VERSION} \
        && ./configure --prefix=$BUILD_PREFIX --enable-dap $HOST_CONFIGURE_FLAGS \
        && make -j4 \
        && make install)
    touch netcdf-stamp
}

# ------------------------------------------


function build_nghttp2 {
    if [ -e nghttp2-stamp ]; then return; fi
    fetch_unpack https://github.com/nghttp2/nghttp2/releases/download/v${NGHTTP2_VERSION}/nghttp2-${NGHTTP2_VERSION}.tar.gz
    (cd nghttp2-${NGHTTP2_VERSION}  \
        && ./configure --enable-lib-only --prefix=$BUILD_PREFIX \
        && make -j4 \
        && make install)
    touch nghttp2-stamp
}

function build_curl_ssl {
    if [ -e curl-stamp ]; then return; fi
    CFLAGS="$CFLAGS -g -O2"
    CXXFLAGS="$CXXFLAGS -g -O2"
    suppress build_nghttp2
    local flags="--prefix=$BUILD_PREFIX --with-nghttp2=$BUILD_PREFIX --with-zlib=$BUILD_PREFIX"
    if [ -n "$IS_MACOS" ]; then
        flags="$flags --with-darwinssl"
    else  # manylinux
        suppress build_openssl
        flags="$flags --with-ssl --without-libpsl"
        LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$BUILD_PREFIX/lib
    fi
    fetch_unpack https://curl.se/download/curl-${CURL_VERSION}.tar.gz
    (cd curl-${CURL_VERSION} \
        && if [ -z "$IS_MACOS" ]; then \
        LIBS=-ldl ./configure $flags; else \
        ./configure $flags; fi\
        && make -j4 \
        && make install)
    touch curl-stamp
}


function build_libtiff {
    if [ -e libtiff-stamp ]; then return; fi
    build_simple tiff $LIBTIFF_VERSION https://download.osgeo.org/libtiff
    touch libtiff-stamp
}

function build_sqlite {
    if [ -z "$IS_MACOS" ]; then
        CFLAGS="$CFLAGS -DHAVE_PREAD64 -DHAVE_PWRITE64"
    fi
    if [ -e sqlite-stamp ]; then return; fi
    build_simple sqlite-autoconf $SQLITE_VERSION https://www.sqlite.org/2024
    touch sqlite-stamp
}


function build_hdf5 {
    if [ -e hdf5-stamp ]; then return; fi
    suppress build_zlib
    # libaec is a drop-in replacement for szip
    suppress build_libaec
    local hdf5_url=https://support.hdfgroup.org/ftp/HDF5/releases
    local short=$(echo $HDF5_VERSION | awk -F "." '{printf "%d.%d", $1, $2}')
    fetch_unpack $hdf5_url/hdf5-$short/hdf5-$HDF5_VERSION/src/hdf5-$HDF5_VERSION.tar.gz
    (cd hdf5-$HDF5_VERSION \
        && export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$BUILD_PREFIX/lib \
        && ./configure --with-szlib=$BUILD_PREFIX --prefix=$BUILD_PREFIX \
        --enable-cxx --enable-threadsafe --enable-unsupported --with-pthread=yes \
        && make -j4 \
        && make install)
    touch hdf5-stamp
}


function build_blosc {
    if [ -e blosc-stamp ]; then return; fi
    suppress get_modern_cmake
    fetch_unpack https://github.com/Blosc/c-blosc/archive/v${BLOSC_VERSION}.tar.gz
    (cd c-blosc-${BLOSC_VERSION} \
        && cmake -DCMAKE_INSTALL_PREFIX=$BUILD_PREFIX . \
        && make install)
    if [ -n "$IS_MACOS" ]; then
        # Fix blosc library id bug
        for lib in $(ls ${BUILD_PREFIX}/lib/libblosc*.dylib); do
            install_name_tool -id $lib $lib
        done
    fi
    touch blosc-stamp
}


function build_geos {
    CFLAGS="$CFLAGS -g -O2"
    CXXFLAGS="$CXXFLAGS -g -O2"
    if [ -e geos-stamp ]; then return; fi
    suppress get_modern_cmake
    fetch_unpack http://download.osgeo.org/geos/geos-${GEOS_VERSION}.tar.bz2
    (cd geos-${GEOS_VERSION} \
        && mkdir build && cd build \
        && cmake .. \
        -DCMAKE_INSTALL_PREFIX:PATH=$BUILD_PREFIX \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET \
        -DBUILD_SHARED_LIBS=ON \
        -DCMAKE_BUILD_TYPE=Release \
        -DENABLE_IPO=ON \
        -DBUILD_APPS:BOOL=OFF \
        -DBUILD_TESTING:BOOL=OFF \
        && cmake --build . -j4 \
        && cmake --install .)
    touch geos-stamp
}


function build_jsonc {
    if [ -e jsonc-stamp ]; then return; fi
    suppress get_modern_cmake
    fetch_unpack https://s3.amazonaws.com/json-c_releases/releases/json-c-${JSONC_VERSION}.tar.gz
    (cd json-c-${JSONC_VERSION} \
        && cmake -DCMAKE_INSTALL_PREFIX=$BUILD_PREFIX -DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET . \
        && make -j4 \
        && make install)
    if [ -n "$IS_OSX" ]; then
        for lib in $(ls ${BUILD_PREFIX}/lib/libjson-c.5*.dylib); do
            install_name_tool -id $lib $lib
        done
        for lib in $(ls ${BUILD_PREFIX}/lib/libjson-c.dylib); do
            install_name_tool -id $lib $lib
        done
    fi
    touch jsonc-stamp
}


function build_proj {
    CFLAGS="$CFLAGS -DPROJ_RENAME_SYMBOLS -g -O2"
    CXXFLAGS="$CXXFLAGS -DPROJ_RENAME_SYMBOLS -DPROJ_INTERNAL_CPP_NAMESPACE -g -O2"
    if [ -e proj-stamp ]; then return; fi
    suppress get_modern_cmake
    suppress build_sqlite
    fetch_unpack http://download.osgeo.org/proj/proj-${PROJ_VERSION}.tar.gz
    suppress build_curl_ssl
    (cd proj-${PROJ_VERSION} \
        && mkdir build && cd build \
        && cmake .. \
        -DCMAKE_INSTALL_PREFIX:PATH=$BUILD_PREFIX \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET \
        -DBUILD_SHARED_LIBS=ON \
        -DCMAKE_BUILD_TYPE=Release \
        -DENABLE_IPO=ON \
        -DBUILD_APPS:BOOL=OFF \
        -DBUILD_TESTING:BOOL=OFF \
        && cmake --build . -j4 \
        && cmake --install .)
    touch proj-stamp
}


function build_sqlite {
    if [ -e sqlite-stamp ]; then return; fi
    fetch_unpack https://www.sqlite.org/2020/sqlite-autoconf-${SQLITE_VERSION}.tar.gz
    (cd sqlite-autoconf-${SQLITE_VERSION} \
        && ./configure --prefix=$BUILD_PREFIX \
        && make -j4 \
        && make install)
    touch sqlite-stamp
}


function build_expat {
    if [ -e expat-stamp ]; then return; fi
    if [ -n "$IS_OSX" ]; then
        :
    else
        fetch_unpack https://github.com/libexpat/libexpat/releases/download/R_2_2_6/expat-${EXPAT_VERSION}.tar.bz2
        (cd expat-${EXPAT_VERSION} \
            && ./configure --prefix=$BUILD_PREFIX \
            && make -j4 \
            && make install)
    fi
    touch expat-stamp
}


function build_lerc {
    if [ -e lerc-stamp ]; then return; fi
    suppress get_modern_cmake
    fetch_unpack https://github.com/Esri/lerc/archive/refs/tags/v${LERC_VERSION}.tar.gz
    (cd lerc-${LERC_VERSION} \
        && mkdir cmake_build && cd cmake_build \
        && cmake .. \
        -DCMAKE_INSTALL_PREFIX=$BUILD_PREFIX \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET \
        -DBUILD_SHARED_LIBS=ON \
        -DCMAKE_BUILD_TYPE=Release \
        -DENABLE_IPO=ON \
        && cmake --build . -j4 \
        && cmake --install .)
    touch lerc-stamp
}


function build_tiff {
    if [ -e tiff-stamp ]; then return; fi
    suppress build_lerc
    suppress build_jpeg
    suppress build_libwebp
    suppress build_zlib
    suppress build_zstd
    suppress build_xz
    fetch_unpack https://download.osgeo.org/libtiff/tiff-${TIFF_VERSION}.tar.gz
    (cd tiff-${TIFF_VERSION} \
        && mv VERSION VERSION.txt \
        && (patch -u --force < ../patches/libtiff-rename-VERSION.patch || true) \
        && ./configure --prefix=$BUILD_PREFIX --enable-zstd --enable-webp --enable-lerc \
        && make -j4 \
        && make install)
    touch tiff-stamp
}


function build_openjpeg {
    if [ -e openjpeg-stamp ]; then return; fi
    suppress build_zlib
    suppress build_tiff
    suppress build_lcms2
    suppress get_modern_cmake
    local archive_prefix="v"
    if [ $(lex_ver $OPENJPEG_VERSION) -lt $(lex_ver 2.1.1) ]; then
        archive_prefix="version."
    fi
    local out_dir=$(fetch_unpack https://github.com/uclouvain/openjpeg/archive/${archive_prefix}${OPENJPEG_VERSION}.tar.gz)
    (cd $out_dir \
        && cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$BUILD_PREFIX -DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET . \
        && make -j4 \
        && make install)
    touch openjpeg-stamp
}


function build_libwebp {
    ls -l $BUILD_PREFIX
    ls -l $BUILD_PREFIX/share
    ls -l $BUILD_PREFIX/share/man
    suppress build_libpng
    suppress build_giflib
    build_simple libwebp $LIBWEBP_VERSION \
        https://storage.googleapis.com/downloads.webmproject.org/releases/webp tar.gz \
        --enable-libwebpmux --enable-libwebpdemux
}


function build_zstd {
    CFLAGS="$CFLAGS -g -O2"
    CXXFLAGS="$CXXFLAGS -g -O2"
    if [ -e zstd-stamp ]; then return; fi
    fetch_unpack https://github.com/facebook/zstd/archive/v${ZSTD_VERSION}.tar.gz
    if [ -n "$IS_OSX" ]; then
        sed_ere_opt="-E"
    else
        sed_ere_opt="-r"
    fi
    (cd zstd-${ZSTD_VERSION}  \
        && make -j4 PREFIX=$BUILD_PREFIX ZSTD_LEGACY_SUPPORT=0 \
        && make install PREFIX=$BUILD_PREFIX SED_ERE_OPT=$sed_ere_opt)
    touch zstd-stamp
}

function build_pcre2 {
    build_simple pcre2 $PCRE_VERSION https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE_VERSION}
}

function build_gdal {
    if [ -e gdal-stamp ]; then return; fi

    suppress build_blosc
    suppress build_lerc
    suppress build_jpeg
    suppress build_libpng
    suppress build_openjpeg
    suppress build_jsonc
    suppress build_sqlite
    suppress build_expat
    suppress build_geos
    suppress build_hdf5
    suppress build_netcdf
    suppress build_zstd
    suppress build_pcre2
    suppress build_proj

    CFLAGS="$CFLAGS -DPROJ_RENAME_SYMBOLS -g -O2"
    CXXFLAGS="$CXXFLAGS -DPROJ_RENAME_SYMBOLS -DPROJ_INTERNAL_CPP_NAMESPACE -g -O2"

    if [ -n "$IS_OSX" ]; then
        GEOS_CONFIG="-DGDAL_USE_GEOS=OFF"
        PCRE2_LIB="$BUILD_PREFIX/lib/libpcre2-8.dylib"
    else
        GEOS_CONFIG="-DGDAL_USE_GEOS=ON"
        PCRE2_LIB="$BUILD_PREFIX/lib/libpcre2-8.so"
    fi

    suppress get_modern_cmake
    fetch_unpack http://download.osgeo.org/gdal/${GDAL_VERSION}/gdal-${GDAL_VERSION}.tar.gz
    (cd gdal-${GDAL_VERSION} \
        && mkdir build \
        && cd build \
        && cmake .. \
        -DCMAKE_INSTALL_PREFIX=$BUILD_PREFIX \
        -DCMAKE_INCLUDE_PATH=$BUILD_PREFIX/include \
        -DCMAKE_LIBRARY_PATH=$BUILD_PREFIX/lib \
        -DCMAKE_PROGRAM_PATH=$BUILD_PREFIX/bin \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET \
        -DBUILD_SHARED_LIBS=ON \
        -DCMAKE_BUILD_TYPE=Release \
        -DGDAL_BUILD_OPTIONAL_DRIVERS=ON \
        -DOGR_BUILD_OPTIONAL_DRIVERS=OFF \
        ${GEOS_CONFIG} \
        -DGDAL_USE_CURL=ON \
        -DGDAL_USE_TIFF=ON \
        -DGDAL_USE_TIFF_INTERNAL=OFF \
        -DGDAL_USE_GEOTIFF_INTERNAL=ON \
        -DGDAL_ENABLE_DRIVER_GIF=ON \
        -DGDAL_ENABLE_DRIVER_GRIB=ON \
        -DGDAL_ENABLE_DRIVER_JPEG=ON \
        -DGDAL_USE_JXL=OFF \
        -DGDAL_USE_ICONV=ON \
        -DGDAL_USE_JSONC=ON \
        -DGDAL_USE_JSONC_INTERNAL=OFF \
        -DGDAL_USE_ZLIB=ON \
        -DGDAL_USE_ZLIB_INTERNAL=OFF \
        -DGDAL_ENABLE_DRIVER_HDF5=ON \
        -DGDAL_USE_HDF5=ON \
        -DHDF5_INCLUDE_DIRS=$BUILD_PREFIX/include \
        -DGDAL_ENABLE_DRIVER_NETCDF=ON \
        -DGDAL_USE_NETCDF=ON \
        -DGDAL_ENABLE_DRIVER_OPENJPEG=ON \
        -DGDAL_ENABLE_DRIVER_PNG=ON \
        -DGDAL_ENABLE_DRIVER_OGCAPI=OFF \
        -DGDAL_USE_SQLITE3=ON \
        -DOGR_ENABLE_DRIVER_SQLITE=ON \
        -DOGR_ENABLE_DRIVER_GPKG=ON \
        -DOGR_ENABLE_DRIVER_MVT=ON \
        -DGDAL_ENABLE_DRIVER_MBTILES=ON \
        -DOGR_ENABLE_DRIVER_OSM=ON \
        -DBUILD_PYTHON_BINDINGS=OFF \
        -DBUILD_JAVA_BINDINGS=OFF \
        -DBUILD_CSHARP_BINDINGS=OFF \
        -DGDAL_USE_SFCGAL=OFF \
        -DGDAL_USE_XERCESC=OFF \
        -DGDAL_USE_LIBXML2=OFF \
        -DGDAL_USE_PCRE2=ON \
        -DPCRE2_INCLUDE_DIR=$BUILD_PREFIX/include \
        -DPCRE2-8_LIBRARY=$PCRE2_LIB \
        -DGDAL_USE_POSTGRESQL=OFF \
        -DGDAL_ENABLE_POSTGISRASTER=OFF \
        -DGDAL_USE_OPENEXR=OFF \
        -DGDAL_ENABLE_EXR=OFF \
        -DGDAL_USE_OPENEXR=OFF \
        -DGDAL_USE_HEIF=OFF \
        -DGDAL_ENABLE_HEIF=OFF \
        -DGDAL_USE_ODBC=OFF \
        -DOGR_ENABLE_DRIVER_AVC=ON \
        -DGDAL_ENABLE_DRIVER_AIGRID=ON \
        -DGDAL_ENABLE_DRIVER_AAIGRID=ON \
        -DGDAL_USE_LERC=ON \
        -DGDAL_USE_LERC_INTERNAL=OFF \
        -DGDAL_USE_PCRE2=OFF \
        -DGDAL_USE_POSTGRESQL=OFF \
        -DGDAL_USE_ODBC=OFF \
        && cmake --build . -j4 \
        && cmake --install .)
    if [ -n "$IS_OSX" ]; then
        :
    else
        strip -v --strip-unneeded ${BUILD_PREFIX}/lib/libgdal.so.* || true
        strip -v --strip-unneeded ${BUILD_PREFIX}/lib64/libgdal.so.* || true
    fi
    touch gdal-stamp
}


# Run installation process
suppress update_env_for_build_prefix

suppress get_modern_cmake
suppress build_openssl
suppress build_xz
suppress build_nghttp2

if [ -n "$IS_OSX" ]; then
    rm /usr/local/lib/libpng* || true
fi

fetch_unpack https://curl.haxx.se/download/curl-${CURL_VERSION}.tar.gz

# Remove previously installed curl.
rm -rf /usr/local/lib/libcurl* || true

suppress build_curl_ssl
suppress build_libwebp
suppress build_zstd
suppress build_libpng
suppress build_jpeg
suppress build_lerc

if [ -n "$IS_OSX" ]; then
    export LDFLAGS="${LDFLAGS} -Wl,-rpath,${BUILD_PREFIX}/lib"
fi

suppress build_tiff
suppress build_openjpeg
suppress build_jsonc
suppress build_sqlite
suppress build_expat
suppress build_geos
suppress build_hdf5
suppress build_netcdf
build_proj

build_gdal
