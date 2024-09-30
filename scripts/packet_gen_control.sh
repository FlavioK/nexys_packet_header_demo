#!/usr/bin/env bash

#
#  Command line:         ./demo 
#                --or--  ./demo dual 
#

#
# Compute the addresses of the AXI registers
#
BASE=0x44A0000
VERSION=$(( BASE + 0x00 ))
START_STOP=$(( BASE + 0x04 ))
STATUS=$(( BASE + 0x08 ))
ADD_LENGTH=$(( BASE + 0x0C ))
CLEAR=$(( BASE + 0x10 ))


#
#  If the user wants to get the module version
#
if [ "$1" == "version" ]; then

    # Left display in hex, right display in decimal
    version=$(axireg -hex $VERSION)
    echo "packet_gen version is $version"
fi

#
#  If the user wants to start/stop the generation
#
if [ "$1" == "control" ]; then

	status=$(axireg -dec $STATUS)
	if [ "$status" == "0" ]; then
		echo "Starting the packet generation"
		axireg $START_STOP 1
		if [ "$?" != "0" ]; then
			echo "Failed to start packet generation"
		fi
	else
		echo "Stoping the packet generation"
		axireg $START_STOP 1
		echo "Waiting until generation has stopped"
		while [ "$(axireg -dec $STATUS)" == "1" ]; do
			sleep .5
		done
		echo "Packet generation has stopped"
	fi

fi

#
#  If the user wants to get the status of the generation
#
if [ "$1" == "status" ]; then
	status=$(axireg -dec $STATUS)
	n_packets=$(axireg -dec $ADD_LENGTH)
	if [ "$status" == "0" ]; then
		echo "Packet generation is not running. Holding $n_packets packets."
	else
		echo "Packet generation is running. Holding $n_packets packets."
	fi
fi

#
#  If the user wants to add a packet
#
if [ "$1" == "add" ]; then
	axireg $ADD_LENGTH $2
	if [ "$?" == "0" ]; then
		echo "Packet with length $2 added."
	else
		echo "Failed to add packet with length $2"
	fi
	n_packets=$(axireg -dec $ADD_LENGTH)
	echo "Holding $n_packets packets."
fi

#
#  If the user wants to add multiple packets with increasing length
#
if [ "$1" == "mult" ]; then
	for i in $(seq 1 $2);
	do
		axireg $ADD_LENGTH $i
		if [ "$?" == "0" ]; then
			echo -ne "Packet with length $i added.\033[0K\r"
		else
			echo " Failed to add packet with length $i"
			break
		fi
	done
	echo""
	n_packets=$(axireg -dec $ADD_LENGTH)
	echo "Holding $n_packets packets."
fi

#
#  If the user wants to clear all packets
#
if [ "$1" == "clear" ]; then
	axireg $CLEAR 1
	if [ "$?" == "0" ]; then
		echo "All packets cleared."
	else
		echo "Failed to clear packets. Are we still running?"
	fi
	n_packets=$(axireg -dec $ADD_LENGTH)
	echo "Holding $n_packets packets."
fi

if [ "$1" == "" ]; then
	# If we get here, the user flubbed the command line
	echo "Run \"./packet_gen_control.sh\" or with one of the following argument combinations:"
	echo "    \"./packet_gen_control.sh version\"             | Get module version"
	echo "    \"./packet_gen_control.sh control\"             | Start/Stop the generation"
	echo "    \"./packet_gen_control.sh status\"              | Get the generation status"
	echo "    \"./packet_gen_control.sh add <packet_length>\" | Add a new packet"
	echo "    \"./packet_gen_control.sh mult <num_packtes>\"  | Add multiple packets"
	echo "    \"./packet_gen_control.sh clear\"               | Clear currently recorded lengths."
fi
