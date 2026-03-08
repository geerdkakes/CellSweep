# CellSweep
Toolset to trace signal strength and up and downlink speed in a certain area.

This tool uses a set of shell scripts that will run on a ubuntu machine with a modem and a gps connected to it. The scripts will run in the background and will log the signal strength and up and downlink speed continuiously to a file.

There are two parts to it. A main controler script to start and stop the logging, and a set of scripts to log the signal strength and up and downlink speed. This will run from the controler (e.g. a laptop). The other part runs on the computer with the modem and GPS connected to it.

On the computer with the modem and GPS the following tools need to be installed:
- atinout (for sending AT commands to the modem, source: https://github.com/beralt/atinout)
- Quectel drivers qmi_wwan_q
- gpsd (for getting the GPS data, source: https://gpsd.gitlab.io/gpsd/)
