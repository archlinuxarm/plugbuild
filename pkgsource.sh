#!/bin/bash
# pkgsource.sh - source pkgbuild and return the stuff we use
# arguments: <abs root> <repo> <package>


source ${1}/${2}/${3}/PKGBUILD > /dev/null 2>&1

string="${pkgname[*]}|${provides[*]}|${pkgver}|${pkgrel}|${depends[*]}|${makedepends[*]}"
if [[ ${plugrel} ]]; then
	string="$string|${plugrel}"
	if [[ ${noautobuild} ]]; then
		string="$string|${noautobuild}"
	else
		string="$string|0"
	fi
fi

echo ${string}
