#!/bin/bash
# pkgsource.sh - source pkgbuild and return the stuff we use
# arguments: <abs root> <repo> <package>

source "${1}/${2}/${3}/PKGBUILD" > /dev/null 2>&1

# build provides from entire PKGBUILD to include pkg definitions, not just global declaration
provides_list=()
eval $(awk '/^[[:space:]]*provides=/,/\)/' "${1}/${2}/${3}/PKGBUILD" | \
    sed -e "s/provides=/provides_list+=/" -e "s/#.*//" -e 's/\\$//')

# build output reply to build server
string="${pkgname[*]}|${provides_list[*]}|${pkgver}|${pkgrel}|${depends[*]}|${makedepends[*]}"

# attach our plugrel and noautobuild declarations, if present
if [[ ${plugrel} ]]; then
    string="$string|${plugrel}"
    if [[ ${noautobuild} ]]; then
        string="$string|${noautobuild}"
    else
        string="$string|0"
    fi
fi

# return
echo ${string}
