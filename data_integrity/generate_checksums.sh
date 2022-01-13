#!/bin/sh

# hashdeep is required for this script to work
### hashdeep command glossary ###
# sha1sum -lr <file/dir> - calculate checksum(s) recursively
# sha1sum -rx <hashsum file> <source file/dir> - calculate and compare checksum(s) recursively and show any discrepancies
# output should be written to a file
### hashdeep command glossary ###

## variables shown below are subject to change depending on your setup ##
working_dir="."	# "." equals to "this directory"
checksum_algo="md5"	# md5 sha1 sha256
checksum_dir="${checksum_algo}sums"
checksum_file_ext="${checksum_algo}deep"
show_current_file="false" # set to true if you need to monitor checksum calculation for large files
## variables shown above are subject to change depending on your setup ##

### persistent variables ###
# set the appropriate input field separator
IFS=$(echo -en "\n\b")
algo_list="md5 sha1 sha256"
self_filename=`basename "$0"`
### persistent variables ###

### script variables ###
parser_stoplist="${checksum_dir} ${checksum_file_ext}"
parser_stoplist_updated="false"
working_eq_script_dir="false"
working_dir_nonexistent="false"
command_base=""
command_flags=""
algo_exists="true"
#first_path="true"
### script variables ###

### functions ###
print_script_parameters() {
	echo "Current script parameters:"
	echo " Working directory: ${working_dir}"
	echo " Parser stoplist: ${parser_stoplist}"
	echo " Checksum algorithm: ${checksum_algo}"
	echo " Checksum output directory: ${checksum_dir}"
	echo " Checksum output file extension: ${checksum_file_ext}"
}
check_algo_name() {
	if ! $(echo $algo_list | grep -w $checksum_algo > /dev/null)
	then
		algo_exists="false"
	else
		algo_exists="true"
	fi
}
create_command_base() {
	command_base="${command_base}${checksum_algo}deep"
}
apply_filenames_by_algo() {
	checksum_dir="${checksum_algo}sums"
	checksum_file_ext="${checksum_algo}deep"
}
### functions ###

# get the script's path
script_path=$(dirname "$(readlink -f '$0')")
if [ $working_dir = "." ]
then
	working_eq_script_dir="true"
	working_dir=$script_path
fi

# check if the checksum_algo exists
check_algo_name
if [ $algo_exists == "false" ]
then
	echo "$checksum_algo algorithm is not found! Are you debugging?"
fi
create_command_base

### user interaction ###
# greet the user
echo -e "Welcome to 0xb1b1's checksum generator!\n"
print_script_parameters

# ask the user if they wish to continue
echo -ne "\nDo you wish to continue? (y/(e)dit/n): "
read user_consent
if [ $user_consent == "e" ] || [ $user_consent == "edit" ]
then
	user_edit_finished="false"
	while [ $user_edit_finished == "false" ]
	do
		echo -n "Which parameter do you wish to edit? (working (dir)ectory/parser (stop)list/(algo)rithm/output (dir)ectory/output file (ext)ension): "
		read user_edit_choice
		if [ $user_edit_choice == "dir" ] || [ $user_edit_choice == "directory" ]
		then
			echo -n "Enter a new working directory (an absolute path): "
			read user_edit_value
			if [ -d $user_edit_value ]
			then
				working_dir=$user_edit_value
				working_eq_script_dir="false"
				working_dir_nonexistent="false"
			else
				working_dir="${user_edit_value} (does not exist)"
				working_dir_nonexistent="true"
				echo -e "\nWARNING: The directory you entered does not exist! If you leave it as it is, the script will halt."
			fi

		elif [ $user_edit_choice == "stop" ] || [ $user_edit_choice == "stoplist" ]
		then
			parser_stoplist_updated="true"
			echo -n "Enter a new parser stoplist (a list of directories and files to ignore): "
			read user_edit_value
			echo -n "Do you wish to save previous values? (Y/n): "
			read user_edit_save_previous
			if [ $user_edit_save_previous == "y" ] || [ $user_edit_save_previous == "yes" ] || [ $user_edit_save_previous == "" ]
			then
				parser_stoplist="${parser_stoplist} ${user_edit_value}"
			elif [ $user_edit_save_previous == "n" ] || [ $user_edit_save_previous == "no" ]
			then
				parser_stoplist="${user_edit_value}"
			fi

		elif [ $user_edit_choice == "algo" ]
		then
			echo -n "Which algorithm do you wish to use? (md5/sha1/sha256): "
			read checksum_algo
			check_algo_name
			echo -n "Set default directory and file names based on the new algorithm? (y/n): "
			read apply_fn_user_consent
			if [ $apply_fn_user_consent == "y" ]
			then
				apply_filenames_by_algo
			fi

		elif [ $user_edit_choice == "dir" ]
		then
			echo -n "Enter a new directory name (will be created if it doesn't exist): "
			read checksum_dir

		elif [ $user_edit_choice == "ext" ]
		then
			echo -n "Enter a new filename extension for all newly created files: "
			read checksum_file_ext
		fi
		
		echo
		print_script_parameters
		echo -ne "\nDo you wish to continue editing? (y/n): "
		read user_continue_editing_consent
		if [ $user_continue_editing_consent == "n" ]
		then
			user_edit_finished="true"
		else
			echo
		fi

		echo
	done
	if [ $algo_exists == "false" ]
	then
		echo -e "$checksum_algo algorithm is not found! Are you debugging?\nHalting."
		exit 1
	fi
elif [ $user_consent != "y" ]
then
	exit 0
fi

# exit if the working_dir doesn't exist
if [ $working_dir_nonexistent == "true" ]
then
	echo "The directory you entered does not exist! Halting."
	exit 1
fi

## update parser_stoplist ##
parser_stoplist="${checksum_dir} ${checksum_file_ext}"

# add custom do-not-scan directories and files
if [ $parser_stoplist_updated == "true" ]
then
	parser_stoplist="${parser_stoplist} ${user_stoplist}"
fi
## update parser_stoplist ##

echo "Please wait while the script generates checksums for every file and directory in ${PWD}"
### user interaction ###

### check if the working directory is empty ###
# check if the script resides in the working_dir
working_dir_count=$(( $(find $working_dir -maxdepth 1 | wc -l)-1 ))

# check if checksum_dir exists
if [ -d "${working_dir}/${checksum_dir}" ]
then
	working_dir_count=$(( $working_dir_count - 1 ))
fi

# check if the working_dir is empty; if true, exit
if [ $working_eq_script_dir == "true" ]
then
	# check if the working_dir is empty (decrement by 1 to account for the script)
	if [ $(( $working_dir_count - 1 )) -lt 1 ]
	then
		echo "The working directory is empty! Halting."
		exit 1
	fi
else
	# check if the working_dir is empty
	if [ $working_dir_count -lt 1 ]
	then
		echo "The working directory is empty! Halting."
		exit 1
	fi
fi
### check if the working directory is empty ###

### add command flags ###
# add necessary command flags
if [ $show_current_file == "true" ]
then
	command_flags="${command_flags} -e"
fi
# add command flags for checksumming
command_flags="${command_flags} -l"
command_flags="${command_flags} -r"
### add command flags ###

# create checksum_dir if needed
mkdir -p "${working_dir}/${checksum_dir}"

### create checksums ###
# cd into the working_dir
cd "$working_dir"

# iterate through all files in the working_dir
for hashdeep_path in *
do
	## skip checksum calculation for the checksum folder ##
	if [ $hashdeep_path == $checksum_dir ] || [ $hashdeep_path == $self_filename ]
	then
		continue
	fi
	## skip checksum calculation for the checksum folder ##

	## skip checksum calculation for files in parser_stoplist ##
	if $(echo $parser_stoplist | grep -w $parser_stoplist > /dev/null)
	then
		continue
	fi
	## skip checksum calculation for files in parser_stoplist ##

	# debug: check if the file/dir parsing script has errors
	#echo "$hashdeep_path"

	## tell the user which file/directory is being traversed ##
	# newline formatting
	#if [ $first_path == "false" ]
	#then
	#	echo
	#	first_path="false"
	#fi
	echo "Calculating checksums for $hashdeep_path"
	## tell the user which file/directory is being traversed ##

	## perform recursive checksum calculation for $hashdeep_path ##
	# construct the command and run it using eval; save to respective files in the checksum_dir and override any previous results
	eval "${command_base} ${command_flags} \"${hashdeep_path}\" > \"${working_dir}/${checksum_dir}\"/\"${hashdeep_path}\".\"${checksum_file_ext}\""
	## perform recursive checksum calculation for $hashdeep_path ##
done
### create checksums ###
