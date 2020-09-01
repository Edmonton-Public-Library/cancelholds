#!/bin/bash
###############################################################################
#
# Removes the most recent hold for customers that have more than one hold on a title.
#
#    Copyright (C) 2020  Andrew Nisbet, Edmonton Public Library
# The Edmonton Public Library respectfully acknowledges that we sit on
# Treaty 6 territory, traditional lands of First Nations and Metis people.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
# MA 02110-1301, USA.
#
###############################################################################

# Environment setup required by cron to run script because its daemon runs
# without assuming any environment settings and we need to use sirsi's.
#######################################################################
# ***           Edit these to suit your environment               *** #
source /s/sirsi/Unicorn/EPLwork/cronjobscripts/setscriptenvironment.sh
###############################################################################
VERSION=0.00.1   # Initial build.
CAT_KEY=''       # Global cat key used to find the title.
TRUE=0
FALSE=1
###############################################################################
# Display usage message.
# param:  none
# return: none
usage()
{
    cat << EOFU
Usage: $0 [-option]
 This script only removes duplicate holds on a title. It should be used in place of cancelholds.pl -kt.

 To refactor this project consider the following. 
1) echo the item id to selitem to get the cat key. 
2) Find the user key, hold key, item key for all the active title holds on that title.
3) Use pipe.pl to output the count of holds for each user key on the title. A side effect of the dedup 
   process in pipe is only the last row to be deduplicated is output which works to our favor because 
   it is also the largest hold key, and therefore the youngest. This means it can be cancelled leaving 
   the oldest, or original hold key intact.
4) Use pipe.pl again to output only counts greater than 1. These are the just the users that have more 
   than one hold on this title.
5) Next order the output so the cat key and sequence number can be used to find the call num (shelving code).
   CallNum   |      #Holds|UserKey|HoldKey|CatKey|CallNum|CopyNum
   Video game 793.93 GHO|2|917862|35594572|2252251|3|1
   Video game 793.93 GHO|2|92559|35590364|2252251|3|1
   Video game 793.93 GHO|2|929556|35601105|2252251|1|1

With that we can reorganize the data to get all the elements we need to cancel a hold Those elements 
are a sequence number, the user's id, the hold key, item id, call num, sequence number, copy number, 
and the number of holds for the user which isn't used in the API transaction but shows if the 
customer have more than two holds on this title?

6) Output the data above moving the item key to the front ready for selitem, and repeating seq. number, 
   and copy number, then all other fields. We also take this oportunity to add a command code sequence 
   number which ranges from 10 to 99.
7) Use selitem to find the barcode in exchange for the item key and pass through everything else to 
the next stage.
8) Trim the barcode which is always padded with trailing spaces, and move the user's key (c5) to the 
front for the next lookup.
9) Use seluser to get the user's barcode in exchange for their user key and pass through everything else.
10) Reorder all columns to match how they are used in the API transaction command line. Again the 
last column indicates how many holds the user has. All the above steps can be rerun on the same 
title to remove additional holds.
S#| UserId       |HoldKey |ItemID      | CallNum             |Seq#|Copy#|#Holds
70|21221019254397|35598291|2252251-3001|Video game 793.93 GHO|3|1|2
71|21221015598482|35622993|2252251-1001|Video game 793.93 GHO|1|1|2
72|21221022164443|35600664|2252251-1001|Video game 793.93 GHO|1|1|2

11) Use the data above to create the apiserver commands with pipe.pl's -m mask command.
We need the server transactions to look like: 
^S87FZFFADMIN^FEEPLMNA^FcNONE^FWADMIN^UODISCARD-BTGFTG^HKTITLE^HH22193634^NQ31221111074451^IQMOR^IS1^dC3^Fv3000000^^O

 -B [item_barcode] remove duplicate holds from the title to which this item barcode belongs.
 -C [cat_key] remove duplicates from the title with this catalogue key.
 -x Prints help message and exits.

   Version: $VERSION
EOFU
    exit 1
}

# Simply populates the $CAT_KEY variable given an item barcode.
# param:  item barcode as an integer.
#
get_cat_key()
{
    if [ -z "$1" ]; then
        echo "**error expected item barcode but got nothing. Exiting."
        exit 3
    else
        CAT_KEY=$( echo $1 | selitem -iB -oC | pipe.pl -oc0 )
    fi
}

# Removes duplicate holds from the title referenced by $CAT_KEY. Confirms before doing
# apiserver commands.
# param:  cat key as an integer.
#
remove_duplicate_holds()
{
    if [ -z "$CAT_KEY" ]; then
        echo "**error no cat key defined. Exiting."
        exit 3
    fi
    local tmp_file=`getpathname tmp`/rmduplicateholds.$CAT_KEY
    # To refactor this project consider the following. 
    # 1) echo the item id to selitem to get the cat key. 
    # 2) Find the user key, hold key, item key for all the active title holds on that title.
    # 3) Use pipe.pl to output the count of holds for each user key on the title. A side effect of the dedup process in pipe is only the last row to be deduplicated is output which works to our favor because it is also the largest hold key, and therefore the youngest. This means it can be cancelled leaving the oldest, or original hold key intact.
    # 4) Use pipe.pl again to output only counts greater than 1. These are the just the users that have more than one hold on this title.
    # 5) Next order the output so the cat key and sequence number can be used to find the call num (shelving code).
    echo $CAT_KEY | selhold -iC -jACTIVE -tT -oUKI | pipe.pl -dc0 -A -P | pipe.pl -Cc0:gt1 | pipe.pl -oc3,c4,c0,c1,c2,c3,c4,c5 | selcallnum -iN -oDS >$tmp_file.1.tmp
    if [ ! -s "$tmp_file.1.tmp" ]; then
        echo "No duplicate holds found on title $CAT_KEY"
        exit 0
    fi
    # CallNum   |      #Holds|UserKey|HoldKey|CatKey|CallNum|CopyNum
    # Video game 793.93 GHO|2|917862|35594572|2252251|3|1
    # Video game 793.93 GHO|2|92559|35590364|2252251|3|1
    # Video game 793.93 GHO|2|929556|35601105|2252251|1|1
    # With that we can reorganize the data to get all the elements we need to cancel a hold Those elements are a sequence number, the user's id, the hold key, item id, call num, sequence number, copy number, and the number of holds for the user which isn't used in the API transaction but shows if the customer have more than two holds on this title?

    # 6) Output the data above moving the item key to the front ready for selitem, and repeating seq. number, and copy number, then all other fields. We also take this oportunity to add a command code sequence number which ranges from 10 to 99.
    # 7) Use selitem to find the barcode in exchange for the item key and pass through everything else to the next stage.
    # 8) Trim the barcode which is always padded with trailing spaces, and move the user's key (c5) to the front for the next lookup.
    # 9) Use seluser to get the user's barcode in exchange for their user key and pass through everything else.
    # 10) Reorder all columns to match how they are used in the API transaction command line. Again the last column indicates how many holds the user has. All the above steps can be rerun on the same title to remove additional holds.
    cat $tmp_file.1.tmp | pipe.pl -oc4,c5,c6,c5,c6,remaining -2c15:10,99 | selitem -iI -oBS | pipe.pl -tc0 -oc5,remaining | seluser -iU -oBS | pipe.pl -oc7,c0,c6,c1,c4,c2,c3,remaining >$tmp_file.2.tmp
    # S#| UserId       |HoldKey |ItemID      | CallNum             |Seq#|Copy#|#Holds
    # 70|21221019254397|35598291|2252251-3001|Video game 793.93 GHO|3|1|2
    # 71|21221015598482|35622993|2252251-1001|Video game 793.93 GHO|1|1|2
    # 72|21221022164443|35600664|2252251-1001|Video game 793.93 GHO|1|1|2
    # 73|21221028065602|35589238|2252251-1001|Video game 793.93 GHO|1|1|2

    # 11) Use the data above to create the apiserver commands with pipe.pl's -m mask command.
    # We need the server transactions to look like: 
    # ^S87FZFFADMIN^FEEPLMNA^FcNONE^FWADMIN^UODISCARD-BTGFTG^HKCOPY^HH22193634^NQ31221111074451^IQMOR^IS1^dC3^Fv3000000^^O
    # which looks like

    cat $tmp_file.2.tmp | pipe.pl -mc0:"^S##FZFFADMIN^FEEPLMNA^FcNONE^FWADMIN",c1:"UO#",c2:"HKTITLE^HH#",c3:"NQ#",c4:"IQ#",c5:"IS#",c6:"dC#",c7:"Fv3000000^^O" -h'^' >$tmp_file.3.tmp
    # ^S10FZFFADMIN^FEEPLMNA^FcNONE^FWADMIN^UO21221021688814^HKTITLE^HH35627742^NQ2252251-1001^IQVideo game 793.93 GHO^IS1^dC1^Fv3000000^^O
    # ^S11FZFFADMIN^FEEPLMNA^FcNONE^FWADMIN^UO21221021599292^HKTITLE^HH35587428^NQ2252251-1001^IQVideo game 793.93 GHO^IS1^dC1^Fv3000000^^O
    # ^S12FZFFADMIN^FEEPLMNA^FcNONE^FWADMIN^UO21221027948378^HKTITLE^HH35601566^NQ2252251-3001^IQVideo game 793.93 GHO^IS3^dC1^Fv3000000^^O
    # ^S13FZFFADMIN^FEEPLMNA^FcNONE^FWADMIN^UO21221022130774^HKTITLE^HH35618816^NQ2252251-3001^IQVideo game 793.93 GHO^IS3^dC1^Fv3000000^^O
    # ^S14FZFFADMIN^FEEPLMNA^FcNONE^FWADMIN^UO21221025309128^HKTITLE^HH35607630^NQ2252251-1001^IQVideo game 793.93 GHO^IS1^dC1^Fv3000000^^O
    
    local transactions="rmduplicatehold.$CAT_KEY.transactions"
    cp $tmp_file.3.tmp $transactions
    local responses=duplicatehold.$CAT_KEY.responses
    local answer=$(confirm "Do you want to continue with removing duplicate holds from title $CAT_KEY ")
    if [ "$answer" == "$FALSE" ]; then
        echo "Exiting, but transactions can be found in file $transactions" >&2
        exit $FALSE
    fi
    if [ -s "$transactions" ]; then
        apiserver -h <$transactions >$responses
    else
        echo "**error $transactions is empty or missing from "`pwd`". Exiting."
        exit 4
    fi
}


# Asks if user would like to do what the message says.
# param:  message string.
# return: 0 if the answer was yes and 1 otherwise.
confirm()
{
	if [ -z "$1" ]; then
		echo "** error, confirm_yes requires a message." >&2
		exit $FALSE
	fi
	local message="$1"
	echo "$message? y/[n]: " >&2
	read answer
	case "$answer" in
		[yY])
			echo "yes selected." >&2
			echo $TRUE
			;;
		*)
			echo "no selected." >&2
			echo $FALSE
			;;
	esac
}

# Argument processing.
while getopts ":B:C:x" opt; do
  case $opt in
    
    B)	echo "["`date +'%Y-%m-%d %H:%M:%S'`"] -B [item_barcode] removing duplicate holds from $OPTARG's title." >&2
        get_cat_key $OPTARG
        remove_duplicate_holds
        ;;
    
    C)	echo "["`date +'%Y-%m-%d %H:%M:%S'`"] -C [cat_key] removing duplicate holds from cat key $OPTARG." >&2
        CAT_KEY=$( echo $OPTARG | pipe.pl -oc0 ) # Makes sure any piped in cat key doesn't have a trailing '|' character.
        remove_duplicate_holds
        ;;

    x)	usage
        ;;

    \?)	echo "Invalid option: -$OPTARG" >&2
        usage
        ;;
  esac
done
exit 0
# EOF
