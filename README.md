# mqtt - hamlib2 bridge

Reads data from rigctl/rotctl and publishes to MQTT server.
Subscribes to mqtt event and sends control commands to rotctld

dependencies:

Net:MQTT:Simple
perl-hamlib
