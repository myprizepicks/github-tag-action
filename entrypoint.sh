#!/bin/bash

set -o pipefail

set_output () {
    echo "$1=$2" >> "$GITHUB_OUTPUT"
}
set_output shortref "$(git rev-parse --short HEAD)"

debug() {
    echo -e "::debug:: $*"
}

# config
default_semvar_bump=${DEFAULT_BUMP:-minor}
with_v=${WITH_V:-false}
release_branches=${RELEASE_BRANCHES:-master,main}
custom_tag=${CUSTOM_TAG:-}
source=${SOURCE:-.}
dryrun=${DRY_RUN:-false}
initial_version=${INITIAL_VERSION:-0.0.0}
tag_context=${TAG_CONTEXT:-repo}
suffix=${PRERELEASE_SUFFIX:-beta}
declare -i verbose
verbose=${VERBOSE:-0}

cd "${GITHUB_WORKSPACE}/${source}" || exit 1

echo "*** CONFIGURATION ***"
echo -e "\tDEFAULT_BUMP: ${default_semvar_bump}"
echo -e "\tWITH_V: ${with_v}"
echo -e "\tRELEASE_BRANCHES: ${release_branches}"
echo -e "\tCUSTOM_TAG: ${custom_tag}"
echo -e "\tSOURCE: ${source}"
echo -e "\tDRY_RUN: ${dryrun}"
echo -e "\tINITIAL_VERSION: ${initial_version}"
echo -e "\tTAG_CONTEXT: ${tag_context}"
echo -e "\tPRERELEASE_SUFFIX: ${suffix}"
echo -e "\tVERBOSE: ${verbose}"
if [ $verbose -gt 1 ]
then
    set -x
fi

git config --global --add safe.directory /github/workspace
current_branch=$(git rev-parse --abbrev-ref HEAD)

pre_release="true"
IFS=',' read -ra branch <<< "$release_branches"
for b in "${branch[@]}"; do
    echo "Is $b a match for ${current_branch}"
    if [[ "${current_branch}" =~ $b ]]
    then
        pre_release="false"
    fi
done
echo "pre_release = $pre_release"

# fetch tags
git fetch --tags

tagFmt="^v?[0-9]+\.[0-9]+\.[0-9]+$"
preTagFmt="^v?[0-9]+\.[0-9]+\.[0-9]+(-$suffix\.[0-9]+)?$"

# get latest tag that looks like a semver (with or without v)
case "$tag_context" in
    *repo*)
        taglist="$(git for-each-ref --sort=-v:refname --format '%(refname:lstrip=2)' | grep -E "$tagFmt")"
        if [ -z "$taglist" ]
        then
            tag=""
        else
            # shellcheck disable=SC2086
            tag="$(semver $taglist | tail -n 1)"
        fi
        pre_taglist="$(git for-each-ref --sort=-v:refname --format '%(refname:lstrip=2)' | grep -E "$preTagFmt")"
        if [ -z "$pre_taglist" ]
        then
            pre_tag=""
        else
            pre_tag="$(semver "$pre_taglist" | tail -n 1)"
        fi
        ;;
    *branch*)
        taglist="$(git tag --list --merged HEAD --sort=-v:refname | grep -E "$tagFmt")"
        # shellcheck disable=SC2086
        tag="$(semver $taglist | tail -n 1)"

        pre_taglist="$(git tag --list --merged HEAD --sort=-v:refname | grep -E "$preTagFmt")"
        pre_tag=$(semver "$pre_taglist" | tail -n 1)
        ;;
    * ) echo "Unrecognised context"; exit 1;;
esac

# if there are none, start tags at INITIAL_VERSION which defaults to 0.0.0
if [ -z "$tag" ]
then
    log=$(git log --pretty='%B')
    tag="$initial_version"
    if [ -z "$pre_tag" ] && $pre_release
    then
      pre_tag="$initial_version"
    fi
else
    log=$(git log "$tag"..HEAD --pretty='%B')
fi

# Set last tag
set_output last_tag "$tag"

# get current commit hash for tag
tag_commit=$(git rev-list -n 1 "$tag")

# get current commit hash
commit=$(git rev-parse HEAD)

if [ "$tag_commit" == "$commit" ]; then
    echo "No new commits since previous tag. Skipping..."
    set_output tag "$tag"
    exit 0
fi

# echo log if verbose is wanted
if [ $verbose -gt 0 ]
then
  echo "$log"
fi

case "$log" in
    *#major* ) new=$(semver -i major "$tag"); major=true; part="major";;
    *#minor* ) new=$(semver -i minor "$tag"); part="minor";;
    *#patch* ) new=$(semver -i patch "$tag"); part="patch";;
    *#none* )
        echo "Default bump was set to none. Skipping..."
        set_output new_tag "$tag"
        set_output tag "$tag"
        exit 0
        ;;
    * )
        if [ "$default_semvar_bump" == "none" ]; then
            echo "Default bump was set to none. Skipping..."
            set_output new_tag "$tag"
            set_output tag "$tag"
            exit 0
        else
            new=$(semver -i "${default_semvar_bump}" "$tag"); part=$default_semvar_bump
        fi
        ;;
esac

if $pre_release
then
    # Already a prerelease available, bump it
    if [[ "$pre_tag" == *"$new"* ]]; then
        new=$(semver -i prerelease "$pre_tag" --preid "$suffix"); part="pre-$part"
    else
        new="$new-$suffix.1"; part="pre-$part"
    fi
fi

echo "$part"

# prefix with 'v'
if $with_v
then
	new="v$new"
fi

if [ -n "$custom_tag" ]
then
    new="$custom_tag"
fi

if $pre_release
then
    debug "Bumping tag ${pre_tag}. \n\tNew tag ${new}"
else
    debug "Bumping tag ${tag}. \n\tNew tag ${new}"
fi

# set outputs
set_output new_tag "$new"
set_output part "$part"
set_output major "$major"

# use dry run to determine the next tag
if $dryrun
then
    set_output tag "$tag"
    exit 0
fi

set_output tag "$new"

# create local git tag
git tag "$new"

# If $deploy_token isn't set, just use $GITHUB_TOKEN (this will keep events from firing)
: "${deploy_token:=$GITHUB_TOKEN}"

unset GITHUB_TOKEN
echo "$deploy_token" | gh auth login --with-token || exit 9

# push it to github
response=$(gh api --method POST \
                  -H "Accept: application/vnd.github+json" \
                  -H "X-GitHub-Api-Version: 2022-11-28" \
                  "repos/$GITHUB_REPOSITORY/git/refs" \
                  -f ref=refs/tags/"$new" \
                  -f sha="$commit")

echo "::debug::Response from github: $response"
