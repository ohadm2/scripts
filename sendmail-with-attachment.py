#!/usr/bin/python

def csvToList(csv_file_spec):
	import csv, os.path
	
	try: 
		#if(os.path.isfile(csv_file_spec)):
			with open(csv_file_spec, 'rb') as f:
				reader = csv.reader(f)
				aList = map(list, reader)

				if aList.count > 0:
					return aList[0]
				else:
					print "Error! Bad file name '" + csv_file_spec + "'."
					return 1
		#else:
		#	print "Error! Bad file name '" + csv_file_spec + "'."
		#	return 0
	
	except IOError:
		print "Error! Bad file name?"
		return 1

def sendMailWithAnAttachment(mail_server_ip, recievers_list_csv_file, file_to_email, subject, body):

	import smtplib
	import socket
	import base64
	import ntpath
	
	from smtplib import SMTPException

	filespec = file_to_email

	filename = ntpath.basename(filespec)

	# Read a file and encode it into base64 format

	try:

		fo = open(filespec, "rb")
	
	except IOError:
		
		print "Error! Bad file name?"
		return 1 

	filecontent = fo.read()
	encodedcontent = base64.b64encode(filecontent)  # base64

	hostname = socket.gethostname()

	sender = hostname + '@gov.il'

	recievers = csvToList(recievers_list_csv_file)
	
	if(recievers == 1):
		print "Exiting due to an error ..."
		exit(1)

	marker = "AUNIQUEMARKER"

	#body ="""
	#This is a test email to send an attachement.
	#"""
	# Define the main headers.
	part1 = """From: %s <%s>
To: 
Subject: %s
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary=%s

--%s
""" % (hostname, sender, subject, marker, marker)

	# Define the message action
#	part2 = """
#Content-Type: text/plain; charset=utf-8; format=flowed
#Content-Transfer-Encoding: 7bit

	part2 = """
%s
--%s
""" % (body, marker)

	# Define the attachment section
	part3 = """Content-Type: text/plain; charset=UTF-8;
name="%s"
Content-Transfer-Encoding: base64
Content-Disposition: attachment;
 filename="%s"

%s
--%s--
""" %(filename,filename,encodedcontent, marker)

	message = part1 + part2 + part3

	try:
		smtpObj = smtplib.SMTP(mail_server_ip)
		smtpObj.sendmail(sender, recievers, message)

		#print message

		print "Successfully sent email"

	except SMTPException:
		print "Error: unable to send email"

#sendMailWithAnAttachment('192.168.180.88', '/root/scripts/mail_recievers.csv', '/var/log/git-auto-log.txt', 'A new git pull was just made!', 'Attached is a git pull result file.')


import sys

MINIMUM_ARGS=5

if len(sys.argv) < MINIMUM_ARGS:
	#if sys.argv[1] == "" or sys.argv[2] == "" or sys.argv[3] == "" or sys.argv[4] == "" or sys.argv[5] == "":
	
	#print csvToList(sys.argv[1])
	
	print "Error! Required parameters missing.\n"
	print "Usage:\n" + sys.argv[0] + " <mail_server_ip> <recievers_list_csv_file> <file_to_email> <subject> <body>"
	print "\nExample:\n " + sys.argv[0] + "  192.168.1.1 <(echo user@org.local) /tmp/fileToSend 'test-mail-subject' 'test-body'"
 
else:
	mail_server_ip = sys.argv[1]
	recievers_list_csv_file = sys.argv[2]
	file_to_email = sys.argv[3]
	subject = sys.argv[4]
	body = sys.argv[5]
		
	sendMailWithAnAttachment(mail_server_ip, recievers_list_csv_file, file_to_email, subject, body)



