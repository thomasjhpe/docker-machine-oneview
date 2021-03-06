#!/bin/bash

function usage {
  echo "Usage: "
  echo "   GITHUB_TOKEN=XXXXX GITHUB_USER=HewlettPackard GITHUB_REPO=docker-machine-oneview ${0} 0.5.x"
}

function display {
  echo "🐳  $1"
  echo
}

function checkError {
  if [[ "$?" -ne 0 ]]; then
    echo "😡   $1"
    exit 1
  fi
}

function createMachine {
  docker-machine rm -f release 2> /dev/null
  docker-machine create -d virtualbox --virtualbox-cpu-count=2 --virtualbox-memory=2048 release
}

# just get the latest tags from the repo
function getLatestTags {
  if git ls-remote --tags origin | git show-ref --tags --exclude-existing > /dev/null 2<&1 ; then
     echo " fetching latest tags"
     git fetch --tags
  fi
}

if [[ -z "${GITHUB_USER}" ]]; then
  echo "Missing GITHUB_USER argument"
  usage
  exit 1
fi

if [[ -z "${GITHUB_REPO}" ]]; then
  echo "Missing GITHUB_REPO argument"
  usage
  exit 1
fi

PROJECT_URL="git@github.com:${GITHUB_USER}/${GITHUB_REPO}.git"

if [[ -z "${GITHUB_TOKEN}" ]]; then
  echo "GITHUB_TOKEN missing"
  usage
  exit 1
fi

VERSION=$1

if [[ -z "${VERSION}" ]]; then
  echo "Missing version argument"
  usage
  exit 1
fi

if [[ ! "${VERSION}" =~ ^[0-9]\.[0-9](\.[0-9])?(-rc[1-9][0-9]*)?$ ]]; then
  echo "Invalid version. It should look like 0.5.1, 0.6 or 0.5.1-rc2"
  exit 1
fi

command -v git > /dev/null 2>&1
checkError "You obviously need git, please consider installing it..."

command -v github-release > /dev/null 2>&1
checkError "github-release is not installed, go get -u github.com/aktau/github-release or check https://github.com/aktau/github-release, aborting."

command -v openssl > /dev/null 2>&1
checkError "You need openssl to generate binaries signature, brew install it, aborting."

getLatestTags

GITHUB_VERSION="v${VERSION}"
RELEASE_DIR="$(dirname "$(git rev-parse --show-toplevel)")/release-${VERSION}"
GITHUB_RELEASE_FILE="github-release-${VERSION}.md"

LAST_RELEASE_VERSION=$(git describe --abbrev=0 --tags)
checkError "Unable to find current version tag"

display "Starting release from ${LAST_RELEASE_VERSION} to ${GITHUB_VERSION} on ${PROJECT_URL} with token ${GITHUB_TOKEN}"
while true; do
    read -p "🐳  Do you want to proceed with this release? (y/n) > " yn
    echo ""
    case $yn in
        [Yy]* ) break;;
        [Nn]* ) exit;;
        * ) echo "😡   Please answer yes or no.";;
    esac
done

if [[ -d "${RELEASE_DIR}" ]]; then
  display "Cleaning up ${RELEASE_DIR}"
  rm -rdf "${RELEASE_DIR}"
  checkError "Can't clean up ${RELEASE_DIR}. You should do it manually and retry"
fi

display "Cloning into ${RELEASE_DIR} from ${PROJECT_URL}"

mkdir -p "${RELEASE_DIR}"
checkError "Can't create ${RELEASE_DIR}, aborting"
git clone -q "${PROJECT_URL}" "${RELEASE_DIR}"
checkError "Can't clone into ${RELEASE_DIR}, aborting"

cd "${RELEASE_DIR}"

display "Bump version number to ${VERSION}"
if [ "$(uname -s)" = "Linux" ]; then
  sed -i "s/Version = \".*-dev\"/Version = \"${VERSION}\"/g" version/version.go
else
  sed -i "" "s/Version = \".*-dev\"/Version = \"${VERSION}\"/g" version/version.go
fi
checkError "Unable to change version in version/version.go"

git add version/version.go
git commit -q -m"Bump version to ${VERSION}" -s
checkError "Can't git commit the version upgrade, aborting"

display "Building in-container style"
USE_CONTAINER=true make clean test build
checkError "Build error, aborting"

display "Generating github release"
cp -f build/release/github-release-template.md "${GITHUB_RELEASE_FILE}"
checkError "Can't find github release template"
CONTRIBUTORS=$(git log "${LAST_RELEASE_VERSION}".. --format="%aN" --reverse | sort | uniq | awk '{printf "- %s\n", $0 }')
CHANGELOG=$(git log "${LAST_RELEASE_VERSION}".. --oneline)

CHECKSUM=""
for file in $(find bin -type f); do
  SHA256=$(openssl dgst -sha256 < "${file}")
  MD5=$(openssl dgst -md5 < "${file}")
  LINE=$(printf "\n * **%s**\n  * sha256 \`%s\`\n  * md5 \`%s\`\n\n" "$(basename ${file})" "${SHA256}" "${MD5}")
  CHECKSUM="${CHECKSUM}${LINE}"
done

TEMPLATE=$(cat "${GITHUB_RELEASE_FILE}")
echo "${TEMPLATE//\{\{VERSION\}\}/$GITHUB_VERSION}" > "${GITHUB_RELEASE_FILE}"
checkError "Couldn't replace [ ${GITHUB_VERSION} ]"

TEMPLATE=$(cat "${GITHUB_RELEASE_FILE}")
echo "${TEMPLATE//\{\{CHANGELOG\}\}/$CHANGELOG}" > "${GITHUB_RELEASE_FILE}"
checkError "Couldn't replace [ ${CHANGELOG} ]"

TEMPLATE=$(cat "${GITHUB_RELEASE_FILE}")
echo "${TEMPLATE//\{\{CONTRIBUTORS\}\}/$CONTRIBUTORS}" > "${GITHUB_RELEASE_FILE}"
checkError "Couldn't replace [ ${CONTRIBUTORS} ]"

TEMPLATE=$(cat "${GITHUB_RELEASE_FILE}")
echo "${TEMPLATE//\{\{CHECKSUM\}\}/$CHECKSUM}" > "${GITHUB_RELEASE_FILE}"
checkError "Couldn't replace [ ${CHECKSUM} ]"

RELEASE_DOCUMENTATION="$(cat ${GITHUB_RELEASE_FILE})"

display "Tagging and pushing tags"
git remote | grep -q remote.prod.url
if [[ "$?" -ne 0 ]]; then
  display "Adding 'remote.prod.url' remote git url"
  git remote add remote.prod.url "${PROJECT_URL}"
fi

display "Checking if remote tag ${GITHUB_VERSION} already exists"
git ls-remote --tags 2> /dev/null | grep -q "${GITHUB_VERSION}" # returns 0 if found, 1 if not
if [[ "$?" -ne 1 ]]; then
  display "Deleting previous tag ${GITHUB_VERSION}"
  git tag -d "${GITHUB_VERSION}" &> /dev/null
  git push -q origin :refs/tags/"${GITHUB_VERSION}"
else
  echo "Tag ${GITHUB_VERSION} does not exist... yet"
fi

display "Tagging release on github"
git tag "${GITHUB_VERSION}"
git push -q remote.prod.url "${GITHUB_VERSION}"
checkError "Could not push to remote url"

display "Checking if release already exists"
github-release info \
    --security-token  "${GITHUB_TOKEN}" \
    --user "${GITHUB_USER}" \
    --repo "${GITHUB_REPO}" \
    --tag "${GITHUB_VERSION}" > /dev/null 2>&1

if [[ "$?" -ne 1 ]]; then
  display "Release already exists, cleaning it up"
  github-release delete \
      --security-token  "${GITHUB_TOKEN}" \
      --user "${GITHUB_USER}" \
      --repo "${GITHUB_REPO}" \
      --tag "${GITHUB_VERSION}"
  checkError "Could not delete release, aborting"
fi

display "Creating release on github"
github-release release \
    --security-token  "${GITHUB_TOKEN}" \
    --user "${GITHUB_USER}" \
    --repo "${GITHUB_REPO}" \
    --tag "${GITHUB_VERSION}" \
    --name "${GITHUB_VERSION}" \
    --description "${RELEASE_DOCUMENTATION}" \
    --pre-release
checkError "Could not create release, aborting"

display "Uploading binaries"
for file in $(find bin -type f); do
  display "Uploading ${file}..."
  github-release upload \
      --security-token  "${GITHUB_TOKEN}" \
      --user "${GITHUB_USER}" \
      --repo "${GITHUB_REPO}" \
      --tag "${GITHUB_VERSION}" \
      --name "$(basename "${file}")" \
      --file "${file}"
  if [[ "$?" -ne 0 ]]; then
    display "Could not upload ${file}, continuing with others"
  fi
done

git remote rm remote.prod.url

rm ${GITHUB_RELEASE_FILE}

echo "There is a couple of tasks your still need to do manually:"
echo "  1. Open the release notes created for you on github https://github.com/${GITHUB_USER}/${GITHUB_REPO}/releases/tag/${GITHUB_VERSION}, you'll have a chance to enhance commit details a bit"
echo "  2. Once you're happy with your release notes on github, copy the list of changes to the CHANGELOG.md"
echo "  3. Update the documentation branch"
echo "  4. Test the binaries linked from the github release page"
echo "  5. Change version/version.go to the next dev version"
echo "  6. Party !!"
echo
echo "The full details of these tasks are described in the RELEASE.md document, available at https://github.com/${GITHUB_USER}/${GITHUB_REPO}/blob/master/docs/RELEASE.md"
