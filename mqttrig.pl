#!/usr/bin/perl
#
# Script gets data from rig and rotator using hamlib2 and publishes to mqtt server.
# Vilius LY3FF, 2020
#
# perl-hamlib required
#
use strict;
use warnings;

use lib '.';

use Hamlib;
use Net::MQTT::Simple;

# mosquitto server
my $mqtt_host = "mqtt.vurk";

# MQTT topikai
my $radio_topic_path="VURK/radio/FT857/";
my $rotator_topic_path="VURK/rotator/vhf/";

my $radio_set_topic_path="VURK/radio/FT857/";
my $rotator_set_topic_path="VURK/rotator/vhf/set/";

# rigctl -h
my $radio_type = 2; 			# 2 - network
my $radio_path = "127.0.0.1:4532"; 	# path or host

#rotctl -h
my $rotator_type = 2; 			# 2 - network
my $rotator_path = "127.0.0.1:4533"; 	# path or host

# limits for set command
my $min_azimuth = 0;
my $max_azimuth = 360;

my $min_elevation = 0;
my $max_elevation = 90;

my $loop = 1;
my $rig_update_interval = 5; # in seconds
my $rot_update_interval = 2; # in seconds
my $print_interval      = 1; # print stats every n seconds

# do not output anything - for use as a service
my $quiet = 1; 
my $is_a_service = 0; # die if something disconnects

my $rig_in_use = 1;
my $rot_in_use = 1;

if ($radio_type   < 1) {$rig_in_use = 0;}
if ($rotator_type < 1) {$rot_in_use = 0;}

if ($rig_in_use == 0 && $rot_in_use == 0){
    die "no point to continue when rig and rotator is not in use";
}

my $mqtt = Net::MQTT::Simple->new($mqtt_host);


# set debug levels for hamlib
Hamlib::rig_set_debug($Hamlib::RIG_DEBUG_NONE);

my $rig;
my $rot;

$SIG{INT} = sub { 
    if ($rot_in_use) { rot_close($rot)     }
    if ($rig_in_use) { rig_close($rig)     }
    print "interrupted..\n";
    exit 0;
};

if ($rig_in_use) { $rig=rig_open($radio_type, $radio_path);     }
if ($rot_in_use) { $rot=rot_open($rotator_type, $rotator_path); }

my ($freq, $mode, $passband, $ptt, $azimuth, $elevation, $direction);
my $rotator_connected = 0;
my $rig_connected 	  = 0;
my $counter=0;

# subscribe to "set" topic
$mqtt->subscribe($rotator_set_topic_path . "azimuth",  \&set_azimuth);
$mqtt->subscribe($rotator_set_topic_path . "elevation", \&set_elevation);

while($loop){
    $counter++;
    $mqtt->tick();	# check if there are waiting subscribed messages 

    #get data only if rig is in use and connected
    if ($rig_in_use && $rig->{state}->{comm_state}==1 &&($counter % $rig_update_interval == 0)){
	$freq 			= get_freq($rig);
	($mode, $passband) 	= get_mode($rig);
	$ptt 			= get_ptt($rig);
	$rig_connected 		= $rig->{state}->{comm_state};
	mqtt_publish_radio($freq, $mode, $passband, $ptt);
    }
    #get data only if rotator is in use and connected
    if ($rot_in_use  &&($counter % $rot_update_interval == 0)){
	if ($rot->{state}->{comm_state}==1){
	    ($azimuth, $elevation)	= get_position($rot);
	    $direction = &azimuth_to_direction($azimuth);
	    $rotator_connected 	= $rot->{state}->{comm_state};
	    mqtt_publish_rotator($azimuth, $elevation, $direction);
	} else {
	if ($is_a_service == 1) { die "Rotator disconnected, restart required"; }
	 
	# do reconnect, which does not work
#		rot_close($rot);
#		$rot=rot_open($rotator_type, $rotator_path); 
	    }
    }

    if (!$quiet && ($counter % $print_interval == 0)) {
        print "Connection states:\n";
	print "Rig / Rotator : $rig_connected / $rotator_connected\n";
	print "Rig / Rot host: $rig->{state}->{rigport}->{pathname}\n";
	print "Frequency     : $freq\n";
	print "Mode/passband : $mode, $passband\n";
	print "PTT           : $ptt\n";
	print "Azimuth/el    : $azimuth ($direction) / $elevation\n";
    }


sleep 1;
}

rot_close($rot);
rig_close($rig);

exit;



#
# Functions

# rig_open(model, "port/host")
# returns rig
sub rig_open(){
    my $model = shift;
    my $port  = shift;
    my $rig   = new Hamlib::Rig($model);
    die "can't create rig model $model" if (!$rig);
    $rig->{state}->{rigport}->{pathname}=$port;
    my $ret_code=Hamlib::Rig::open($rig);
#    print "ret_code: '$ret_code'\n";
    return $rig;
}

sub rot_open(){
    my $model = shift;
    my $port  = shift;
    my $rot   = new Hamlib::Rot($model);
    die "can't create rot model $model" if (!$rot);
    $rot->{state}->{rotport}->{pathname}=$port;
    my $ret_code=Hamlib::Rot::open($rot);
    return $rot;
}

# rig_close($rig) 
sub rig_close(){
    Hamlib::Rig::close(shift);
}

# rot_close($rig)
sub rot_close(){
    Hamlib::Rot::close(shift);
}

#get_freq($rig)
sub get_freq{
    return shift->get_freq();
}

sub get_mode{
    my ($mode, $pass)= shift->get_mode();
    my $txtMode=Hamlib::rig_strrmode($mode);
    return($txtMode, $pass);
}

sub get_position{
    my ($azimuth, $elevation)= shift->get_position();
    return($azimuth, $elevation);
}


# grazina ptt busena, reikia rig
sub get_ptt{
return shift->get_ptt();
}


#    mqtt_publish_radio($freq, $mode, $passband, $ptt);
sub mqtt_publish_radio{
    $mqtt->publish($radio_topic_path . "frequency" 	=> shift);
    $mqtt->publish($radio_topic_path . "mode" 		=> shift);
    $mqtt->publish($radio_topic_path . "passband" 	=> shift);
    $mqtt->publish($radio_topic_path . "ptt" 		=> shift);
}


#    mqtt_publish_rotator($azimuth, $elevation, $direction);
sub mqtt_publish_rotator{
    $mqtt->publish($rotator_topic_path . "azimuth" 	=> shift);
    $mqtt->publish($rotator_topic_path . "elevation" 	=> shift);
    $mqtt->publish($rotator_topic_path . "direction" 	=> shift);
}

# simple azimuth to direction conversion
sub azimuth_to_direction{
    my $angle = shift;
    my @angles=    (  0,   45,  90,  135, 180,  225, 270,  315, 360);
    my $puse  =  ($angles[1] / 2);
    my @directions=("N", "NE", "E", "SE", "S", "SW", "W", "NW", "N");
    my $direction;
    for (my $i = 0; $i<@angles; $i++){
	if (($angle >= ($angles[$i] - $puse) ) && ( $angle <= ($angles[$i] + $puse) )) { $direction = $directions[$i]; last}
    }
    return $direction;
}


sub set_azimuth{
    my ($topic, $message) = @_;
    if (!$quiet) {print "$topic -> $message\n";}
    if (!( $message =~ /^-?\d+$/)) {
	if (!$quiet) { print "'$message' is not a digit"; }
	return;
    }  
    if (($message >= $min_azimuth) && ($message <= $max_azimuth)) {
	my ($azimuth, $elevation)= $rot->get_position();
	$rot->set_position($message, $elevation);
    }
}

sub set_elevation{
    my ($topic, $message) = @_;
    if (!$quiet) {print "$topic -> $message\n";}
    if (!( $message =~ /^-?\d+$/)) {
	if (!$quiet) { print "'$message' is not a digit"; }
	return;
    }
    if (($message >= $min_elevation) && ($message <= $max_elevation)) {
	my ($azimuth, $elevation)= $rot->get_position();
	$rot->set_position($azimuth, $message);
    }
}

sub test_directions{
    my $step=shift;
    if ($step == 0) {$step =1};
    for (my $i = 0; $i <= 360; $i+=$step){
        my $n = $i;
        my $dir = &azimuth_to_direction($n);
        print "$n \t= ". $dir . "\n";
    }
}
