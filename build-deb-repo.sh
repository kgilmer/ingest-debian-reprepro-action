#!/bin/bash
# This script can be used to generate Debian packages and add them to a local debian repository.

# Input Parameters
if [ "$#" -lt 5 ]; then
    echo "This script builds Debian packages.  It uses a package model file that describes each package."
    echo "Each package is checked out of a git repo, source is downloaded, built, and then deployed to a PPA."
    echo "If no package name is specified from the model, all packages are built."
    echo "Usage: build-deb-repo.sh <package model> <repo path> <temp build dir> <distribution codename> <arch list> [package]"
    exit 1
fi

# Common functions for build scripts

print_banner() {
    echo "***********************************************************"
    echo "** $1"
    echo "***********************************************************"
}

# Checkout
checkout() {
    if [ -z "${packageModel[source]}" ]; then 
        echo "Package model is invalid.  Model field 'source' undefined, aborting."
        exit 1
    fi

    repo_url=${packageModel[source]}
    repo_path=${repo_url##*/}
    repo_name=${repo_path%%.*}
    
    if [ -d "$BUILD_DIR/$repo_name" ]; then
        echo "Deleting existing repo, $repo_name"
        rm -Rfv "${BUILD_DIR:?}/$repo_name"
    fi

    if [ ! -d "$BUILD_DIR" ]; then 
        echo "Creating build directory $BUILD_DIR"
        mkdir -p "$BUILD_DIR" || { echo "Failed to create build dir $BUILD_DIR, aborting."; exit 1; }
    fi

    print_banner "Checking out ${packageModel[source]} into $BUILD_DIR"

    cd "$BUILD_DIR" || exit
    git clone --recursive "${packageModel[source]}" -b "${packageModel[branch]}"
    
    cd - > /dev/null 2>&1  || exit
}

sanitize_git() {
    if [ -d  ".github" ]; then 
        rm -Rf .github 
        echo "Removed $(pwd).github directory before building to appease debuild."
    fi
    if [ -d  ".git" ]; then 
        rm -Rf .git
        echo "Removed $(pwd).git directory before building to appease debuild."
    fi
}

# Stage package source in prep to build 
stage_source() {
    print_banner "Preparing source for ${packageModel[name]}"
    cd "$BUILD_DIR/${packageModel[name]}"  || exit
    full_version=$(dpkg-parsechangelog --show-field Version)
    debian_version="${full_version%-*}"
    cd "$BUILD_DIR" || exit
    
    if [ "${packageModel[upstreamTarball]}" != "" ]; then
        echo "Downloading source from ${packageModel[upstreamTarball]}..."
        wget ${packageModel[upstreamTarball]} -O ${packageModel[name]}/../${packageModel[name]}\_$debian_version.orig.tar.gz
    else
        echo "Generating source tarball from git repo."
        tar cfzv ${packageModel[name]}\_${debian_version}.orig.tar.gz --exclude .git\* --exclude debian ${packageModel[name]}/../${packageModel[name]}
    fi
}

# Build
build_src_package() {
    print_banner "Building source package ${packageModel[name]}"
    cd "$BUILD_DIR/${packageModel[name]}" || exit
    
    sanitize_git    
    sudo apt build-dep -y .
    debuild -S -sa
    cd "$BUILD_DIR" || exit
}

build_bin_package() {
    print_banner "Building binary package ${packageModel[name]}"
    cd "$BUILD_DIR/${packageModel[name]}"  || exit
    
    sanitize_git
    debuild -sa -b
    cd "$BUILD_DIR" || exit
}

cache_model() {    
    PACKAGE_MODEL_FILE="$BUILD_DIR/pkg-model.json"

    if [ -f "$PACKAGE_MODEL_FILE" ]; then 
        echo "Removing stale cache $PACKAGE_MODEL_FILE"
        rm "$PACKAGE_MODEL_FILE" || { echo "Failed to delete cache file, aborting."; exit 1; }
    fi

    cat >"$PACKAGE_MODEL_FILE"

#    while IFS= read -r line; do
#        printf '%s\n' "$line" > "$PACKAGE_MODEL_FILE"
#    done
}

# The following look extracts package objects from the model, creates a map of the values,
# and then passes that map to bash functions for processing.  The script that calls this function
# must declare a function called 'handle_package' and the model data will be provided in a map
# called 'packageModel'.
#
# For each iteration, if $PACKAGE_FILTER is defined, eval does not occur if string match of 'name' fails
#
# Model fields:
# modelDescription: Description for package model (common for all packages in model file)
# name: (Optional) Regolith name for a linux package. Default is Debian naming if exists.  May be overridden
#           by specifying property 'name' in object.  If unspecifed object key is used.
# source: SCM URL from which the package can be cloned.
# branch: branch to pull source from to build
# upstreamTarball: (optional)
read_package_model() {
    jq -rc 'delpaths([path(.[][]| select(.==null))]) | .packages | keys | .[]' < "$PACKAGE_MODEL_FILE" | while IFS='' read -r package; do
        # Set the package name and model desc
        packageModel["name"]="$package"    
        packageModel["modelDescription"]=$(jq -r ".description.title" < "$PACKAGE_MODEL_FILE" )
        # Set all kvps on the associated object
        while IFS== read -r key value; do
            packageModel["$key"]="$value"
        done < <( jq -r ".packages.\"$package\" | to_entries | .[] | .key + \"=\" + .value" < "$PACKAGE_MODEL_FILE" )

        # If a package filter was specified, match filter.
        if [[ -n "$PACKAGE_FILTER" && "$PACKAGE_FILTER" != *"${packageModel[name]}"* ]]; then
            continue
        fi

        # Apply functions to package model
        print_banner "handle_package(${packageModel[name]})"
        handle_package
    done
}

# shellcheck disable=SC2034
PACKAGE_MODEL_FILE=$(realpath "$1")
REPO_PATH=$(realpath "$2")
BUILD_DIR=$3
DIST_CODENAME=$4
PKG_ARCH=$5
PACKAGE_FILTER="${@:6}"

# Determine if the changelog has the correct distribution codename
dist_valid() {
    cd "${BUILD_DIR:?}/${packageModel[name]}"


    TOP_CHANGELOG_LINE=$(head -n 1 debian/changelog)
    CHANGELOG_DIST=$(echo "$TOP_CHANGELOG_LINE" | cut -d' ' -f3 )

    cd - > /dev/null 2>&1
    # echo "Checking $DIST_CODENAME and $CHANGELOG_DIST"
    if [[ "$CHANGELOG_DIST" == *"$DIST_CODENAME"* ]]; then
        return 0
    else 
        return 1
    fi
}

# Update the changelog to specify the target distribution codename
update_changelog() {
    cd "${BUILD_DIR:?}/${packageModel[name]}"
    version=$(dpkg-parsechangelog --show-field Version)
    dch --distribution $DIST_CODENAME --newversion "${version}-1regolith-$(date +%s)" "Automated release."

    cd "$BUILD_DIR"
}

# Check if the source package is already in the repo
source_pkg_exists() {    
    SRC_PKG_VERSION=$(reprepro --basedir "$REPO_PATH" list "$DIST_CODENAME" "$1" | cut -d' ' -f3)

    SRC_PKG_BUILD_VERSION=$(echo $2 | cut -d'-' -f1)
    SRC_PKG_REPO_VERSION=$(echo $SRC_PKG_VERSION | cut -d'-' -f1)

    if [ "$SRC_PKG_REPO_VERSION" == "$SRC_PKG_BUILD_VERSION" ]; then
        return 0
    else
        return 1
    fi
}

# Publish
publish_deb() {    
    set -x
    cd "${BUILD_DIR:?}/${packageModel[name]}"
    version=$(dpkg-parsechangelog --show-field Version)
    cd "$BUILD_DIR"

    DEB_SRC_PKG_PATH="$(pwd)/${packageModel[name]}_${version}_source.changes"
    
    if [ ! -f "$DEB_SRC_PKG_PATH" ]; then
        echo "Failed to find changes file."
    fi

    if source_pkg_exists "${packageModel[name]}" "$version"; then
        echo "Ignoring source package, already exists in target repository"        
    else 
        print_banner "Ingesting source package ${packageModel[name]} into $REPO_PATH"
        reprepro --basedir "$REPO_PATH" include "$DIST_CODENAME" "$DEB_SRC_PKG_PATH"
    fi

    DEB_CONTROL_FILE="$BUILD_DIR/${packageModel[name]}/debian/control"

    for target_arch in $(echo $PKG_ARCH | sed "s/,/ /g"); do        
        cat "$DEB_CONTROL_FILE" | grep ^Package: | cut -d' ' -f2 | while read -r bin_pkg; do 
            DEB_BIN_PKG_PATH="$(pwd)/${bin_pkg}_${version}_${target_arch}.deb"
            if [ -f "$DEB_BIN_PKG_PATH" ]; then
                print_banner "Ingesting binary package ${bin_pkg} into $REPO_PATH"
                reprepro --basedir "$REPO_PATH" includedeb "$DIST_CODENAME" "$DEB_BIN_PKG_PATH"
            else
                echo "Package $DEB_BIN_PKG_PATH does not exist for $target_arch"
            fi
        done
    done
}

# Verify execution environment
env_check() {    
    hash git 2>/dev/null || { echo >&2 "Required command git is not found on this system. Please install it. Aborting."; exit 1; }
    hash debuild 2>/dev/null || { echo >&2 "Required command debuild is not found on this system. Please install it. Aborting."; exit 1; }
    hash jq 2>/dev/null || { echo >&2 "Required command jq is not found on this system. Please install it. Aborting."; exit 1; }
    hash dpkg-parsechangelog 2>/dev/null || { echo >&2 "Required command dpkg-parsechangelog is not found on this system. Please install it. Aborting."; exit 1; }
    hash realpath 2>/dev/null || { echo >&2 "Required command realpath is not found on this system. Please install it. Aborting."; exit 1; }
}

handle_package() {
    checkout
    update_changelog
    if dist_valid; then
        stage_source
        build_src_package
        build_bin_package
        publish_deb
    else
        echo "dist codename does not match in package changelog, ignoring ${packageModel[name]}."
    fi
}

# Main
set -e
# set -x

env_check
if [ ! -d "$BUILD_DIR" ]; then
    mkdir -p "$BUILD_DIR"
fi

print_banner "Generating packages in $BUILD_DIR"

typeset -A packageModel

read_package_model
