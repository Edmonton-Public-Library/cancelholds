#!/usr/bin/perl -w
####################################################
#
# Perl source file for project holdbot 
# Purpose: Cancel holds.
# Method:  API.
#
# Cancels and places any holds on SirsiDynix Symphony ILS.
#    Copyright (C) 2013  Andrew Nisbet
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
# Author:  Andrew Nisbet, Edmonton Public Library
# Created: Tue Mar 18 09:30:05 MDT 2014
# Rev: 
#          0.1 - Development after some time away. 
#          0.0 - Dev. 
#
####################################################

use strict;
use warnings;
use vars qw/ %opt /;
use Getopt::Std;

# Environment setup required by cron to run script because its daemon runs
# without assuming any environment settings and we need to use sirsi's.
###############################################
# *** Edit these to suit your environment *** #
$ENV{'PATH'}  = qq{:/s/sirsi/Unicorn/Bincustom:/s/sirsi/Unicorn/Bin:/usr/bin:/usr/sbin};
$ENV{'UPATH'} = qq{/s/sirsi/Unicorn/Config/upath};
###############################################

my $WORKING_DIR= qq{.};
my $HOLD_TRX   = "$WORKING_DIR/cancel_hold.trx";
my $HOLD_RSP   = "$WORKING_DIR/cancel_hold.rsp";
my $TMP        = "$WORKING_DIR/cancel_hold.tmp";
my $VERSION    = qq{0.1};

#
# Message about this program and how to use it.
#
sub usage()
{
    print STDERR << "EOF";

	usage: $0 [-xU] -B<barcode> 
Cancels copy level holds. The script expects a list of items on stdin
which must have the barcode of the item; one per line.

Use the '-B' switch will determine which user account is 
to be affected.

 -B: REQUIRED User ID.
 -U: Actually places or removes holds. Default just produce transaction commands.
 -x: This (help) message.

example: 
 $0 -x
 cat user_keys.lst | $0 -B 21221012345678 -U
 cat user_keys.lst | $0 -B 21221012345678 
 cat item_keys.lst | $0
 
Version: $VERSION
EOF
    exit;
}

# Kicks off the setting of various switches.
# param:  
# return: 
sub init
{
    my $opt_string = 'B:Ux';
    getopts( "$opt_string", \%opt ) or usage();
    usage() if ( $opt{'x'} );
    usage() if ( ! $opt{'B'} );
}

# Trim function to remove whitespace from the start and end of the string.
# param:  string to trim.
# return: string without leading or trailing spaces.
sub trim( $ )
{
	my $string = shift;
	$string =~ s/^\s+//;
	$string =~ s/\s+$//;
	return $string;
}

# Selects all the holds for a user.
# param:  User key
# param:  hash of itemId->holdKey
# return: 
sub getUserHolds( $$ )
{
	my $userID   = shift;
	my $holdHash = shift;
	chomp( $userID );
	my $results  = `echo "$userID" | seluser -iB -oU | selhold -iU -oIK 2>/dev/null | selitem -iI -oBS 2>/dev/null`;
	# Which produces something like:
	# Item ID         |Holdkey|
	# 31221052193963  |8863617|
	# 738812-1001     |8914672|
	# 31221073080421  |9098195|
	my @lines = split( '\n', $results );
	for my $line ( @lines )
	{
		my ( $itemId, $holdKey ) = split( '\|', $line );
		$itemId = trim( $itemId );
		$holdHash->{$itemId} = $holdKey;
	}
}

# Selects item ids and call nums for all holds from input.
# param:  hash of itemId->holdKey
# return: 
sub getItemCallnum( $ )
{
	my $hashRef = shift;
	my $selection = `cat "$TMP" | selitem -iB -oNBI | selcallnum -iN -oSA`;
	# Split on the selection lines and match barcodes to shelving keys.
	my @lines = split ( '\n', $selection );
	foreach my $line ( @lines )
	{
		my ( $itemId, $catKey, $callSeq, $copyNum, $callnum ) = split( '\|', $line );
		$itemId = trim( $itemId );
		$hashRef->{$itemId} = "$callnum $copyNum";
	}
}

# E201411201028360688R ^S82FZFFADMIN^FEEPLMNA^FcNONE^FWADMIN^UODISCARD-BTGFTG^HKCOPY^HH22193634
# ^NQ31221111074451^IQMOR^IS1^dC3^Fv3000000^^O
#
# 11/20/2014,10:28:36 Station: 0688 Request: Sequence #: 82 Command: Remove Hold
# station login user access:ADMIN  station library:EPLMNA  station login clearance:NONE  
# station user's user ID:ADMIN  user ID:DISCARD-BTGFTG  hold type:COPY  hold number:22193634  
# item ID:31221111074451  call number:MOR  copy number:1  Client type: see client_types.h for values:3  
# Max length of transaction response:3000000

# Cancels the holds on the argument hash references.
# param:  user id (barcode).
# param:  hash of item ids and hold keys.
# param:  hash of item ids and callnums.
# return: count of holds cancelled.
sub cancelHolds( $$$ )
{
	my $userId = shift;
	my $itemIdHoldKeyHash = shift;
	my $itemIdCallnumHash = shift;
	my $transactionSequenceNumber = 0;
	my $count                     = 0;
	open TRX, ">$HOLD_TRX" or die "**Error: unable to open transaction file '$HOLD_TRX', $!\n";
	while( my ( $itemId, $callNumCopyNum ) = each %$itemIdCallnumHash ) 
	{
		# We had to concat the copy number to the callnum so split it now.
		my ( $callNumber, $copyNumber ) = split( ' ', $callNumCopyNum );
		# Use the itemId to find the hold key.
		my $holdKey = $itemIdHoldKeyHash->{ $itemId };
		if ( ! defined $holdKey or ! defined $callNumber or ! defined $copyNumber )
		{
			next;
		}
		$transactionSequenceNumber = 1 if ( $transactionSequenceNumber++ >= 99 );
		print TRX getCancelHoldTransaction( $userId, $holdKey, $itemId, $callNumber, $copyNumber, $transactionSequenceNumber );
		$count++;
	}
	close TRX;
	return $count;
}


#
# 11/20/2014,10:28:36 Station: 0688 Request: Sequence #: 82 Command: Remove Hold
# station login user access:ADMIN  station library:EPLMNA  station login clearance:NONE  
# station user's user ID:ADMIN  user ID:DISCARD-BTGFTG  hold type:COPY  hold number:22193634  
# item ID:31221111074451  call number:MOR  copy number:1  Client type: see client_types.h for values:3  
# Max length of transaction response:3000000
#
# Creates an APIServer remove hold command for a specific item.
# param:  $userId string - Id of the DISCARD card. 
# param:  $holdKey string - item hold key. 
# param:  $itemId string - item id of the hold to cancel.
# param:  $callNumber string - item's call number, or shelving key. 
# param:  $copyNumber string - item's copy number. 
# param:  $sequenceNumber integer - for transaction collision avoidance. 
# return: string of api command.
sub getCancelHoldTransaction( $$$$$$ )
{
	my ( $userId, $holdKey, $itemId, $callNumber, $copyNumber, $sequenceNumber ) = @_;
	# looks like: 
	# E201411201028360688R ^S82FZFFADMIN^FEEPLMNA^FcNONE^FWADMIN^UODISCARD-BTGFTG^HKCOPY^HH22193634
	# ^NQ31221111074451^IQMOR^IS1^dC3^Fv3000000^^O
	my $transactionRequestLine = '^S';
	$transactionRequestLine .= $sequenceNumber = '0' x ( 2 - length( $sequenceNumber ) ) . $sequenceNumber;
	$transactionRequestLine .= 'FZFFADMIN';
	$transactionRequestLine .= '^FEEPLMNA';
	$transactionRequestLine .= '^FcNONE';
	$transactionRequestLine .= '^FWADMIN';
	$transactionRequestLine .= '^UO'.$userId;
	$transactionRequestLine .= '^HKCOPY';
	$transactionRequestLine .= '^HH'.$holdKey;
	$transactionRequestLine .= '^NQ'.$itemId;
	$transactionRequestLine .= '^IQ'.$callNumber;
	$transactionRequestLine .= '^IS'.$copyNumber;
	$transactionRequestLine .= '^dC3'; # workflows.
	# $transactionRequestLine .= '^OM';  # master override (and why not?)
	$transactionRequestLine .= '^Fv3000000';
	$transactionRequestLine .= '^^O';
	return "$transactionRequestLine\n";
}

init();

open HOLDKEYS, ">$TMP"  or die "**Error: unable to open tmp file '$TMP', $!\n";
while (<>) 
{
	# Item barcodes coming in, ignore lines that aren't real barcodes.
	if ( ! m/^\d{14,}/ )
	{
		print STDERR "*Warning: ignoring invalid item '$_'.\n";
		next;
	}
	print HOLDKEYS;
}
close HOLDKEYS;

# Find the user's hold keys. We need to find the user's hold keys because
# tools like selhold don't work with item keys only catalog keys.
my $itemIdHoldKeyHash = {};
getUserHolds( $opt{'B'}, $itemIdHoldKeyHash );
# This will store the items we want to cancel holds on and the callnums we need to do that job.
my $itemIdCallnumHash = {};
getItemCallnum( $itemIdCallnumHash );
# now create the transactions
cancelHolds( $opt{'B'}, $itemIdHoldKeyHash, $itemIdCallnumHash );
unlink $TMP;
if ( $opt{'U'} )
{
	`apiserver -h <$HOLD_TRX >$HOLD_RSP` if ( -s $HOLD_TRX );
}
# EOF
