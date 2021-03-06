#!/bin/bash

if [ "$1" == "" ]; then
	echo "ERROR! Wrong Input."
	echo "Usage: $0 <tar.gz_archive_file_to_check>"
else
	
fi

case $1 in

	"$PROD_ENV_NAME") WORKING_ENV=prod
	;;
	"$TEST_ENV_NAME") WORKING_ENV=test
	;;
	*) WORKING_ENV=
esac




# Using parameters gotten from the user. "-o" means "or", -a means "and"
if [ "$1" == "" -o "$2" == "" ]; then
	echo ERROR: Wrong Input. Usage: $0 \<dns_of_new_site_without_e\>
else
fi

# Getting a sub string from a string

STR="a-string-to-check"

# get only last 2 chars
echo "${STR:${#STR}-2}"

# get all but last 2 chars
echo "${STR:0:${#STR}-2}"

# get all but 2 first chars
echo "${STR:2}"

# get only 2 first chars
echo ${STR:0:2}

# get number of tokens in a string (the delimiter is space)

ARR='some string with words'

ARR=($ARR)

echo ${#ARR[@]}
 

# Get script location
echo `dirname ${BASH_SOURCE[0]}`


# Run a command on a find result list

find . -name "settings.php" -exec grep ^\$conf.*base_url.* {} \;


# Run a set of commands via loop based on a bash command result

# Example 1

for i in $(ls); do 
	echo $i
	mv $i /tmp
done

# Example 2

for i in $(find . -name "$DRUPAL_SETTINGS_FILE"); do 
	echo $i
	cp $i /tmp
done

# Example 3

TOKENS="/dir1 /dir2"

for i in $(echo "$TOKENS"); do
	echo $i
done


# Example 4

TOKENS="/dir1 /dir2"

for i in $TOKENS; do
	echo $i
done

	
# Conditions:
# ! = not
# "-a" = checks if a file exists
# "-d" = checks if a dir exists
# "-h" = check if a symbolic link exists
# "-s" = checks if a file exists and not empty
# "-z" = checks if a STRING is not empty
# The SPACES are a MUST since the signs [ and ] are files!

if ! [ -s /etc/init.d/httpd ]; then
else
fi

if ! [ -z "$SOME_VAR" ]; then
else
fi

if [ -d "dir_to_check" ]; then
fi

if ! [ -h "symbolic_link_to_check" ]; then
fi

# Check a status of a last command. "0" means succes!

# Your command goes here before the condition.

cp a b

if ! [ "$?" == "0" ]; then
	echo Your last command was NOT a success! 
fi

# Using math \ counters

COUNTER=1

for i in $(ls); do
	echo $COUNTER\) $i
	COUNTER=$(expr $COUNTER + 1)
done



# Using sed:

# sed -i = overwite the file with the changes (without -i sed will only print the change)

#/g = "greedy" - replace again and again if found more than once

# sed -i "s/findThisText/replaceItWithThisText/g" file_to_update

# sed -i "s/\<.*\>/\<new_stuff\>/g" file_to_update
				     
#sed "s/\(.*base_url.*\)/\#\1/g" settings.php

#grep -v "#" $SETTINGS_FILE_NAME | grep -v "^//" | grep -v "*" | sed "s/$base_url\(.*\):\/\/.*;/$base_url\1:\/\/$FQDN;/g" 

#grep -v "*" $SETTINGS_FILE_NAME | sed "s/'database'\s*=>\s*'.*'/'database' => '"$2"'/g"
	
