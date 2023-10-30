#!/usr/bin/perl
#
# Script gets data from rig and rotator using hamlib2, then publishes it to mqtt server.
# Script gets data from mqtt server and sends to hamlib2 servers 
# Vilius LY3FF, 2020-2022
#
# perl-hamlib required
#
use strict;
#use warnings;

use lib '.';

use Hamlib;
use Net::MQTT::Simple;
use Time::HiRes qw( gettimeofday tv_interval sleep );

# mosquitto server
my $mqtt_host = "mqtt.vurk";

# MQTT topikai
my $radio_topic_path="VURK/radio/IC9700/";
my $rotator_topic_path="VURK/rotator/vhf/";

my $radio_set_topic_path="VURK/radio/IC9700/set/";
my $rotator_set_topic_path="VURK/rotator/vhf/set/";

# rigctl -h
my $radio_type = 2; 			# 2 - network
#my $radio_path = "127.0.0.1:4532"; 	# path or host
my $radio_path = "192.168.42.10:4532"; 	# path or host

#rotctl -h
my $rotator_type = 2; 			# 2 - network
my $rotator_path = "127.0.0.1:4533"; 	# path or host

# limits for set command
my $min_azimuth = 0;
my $max_azimuth = 360;

my $min_elevation = 0;
my $max_elevation = 90;

my $min_vhf_frequency = 144000000;
my $max_vhf_frequency = 146000000;

my $min_uhf_frequency = 430000000;
my $max_uhf_frequency = 440000000;

my $radio_set_ptt_control_enabled = 0; #  if 1, then PTT control is enabled
my $radio_set_ptt_on_enabled = 0; # (!!)  if set to 1, then ability to set PTT to ON will be enabled.

my $loop = 1;
my $rig_update_interval = 5; # in seconds
my $rot_update_interval = 2; # in seconds
my $print_interval      = 1; # print stats every n seconds

# do not output anything - for use as a service
my $quiet = 0; 
my $is_a_service = 0; # die if something disconnects

my $rig_in_use = 0;
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
my $rig_timer;
my $rot_timer;
my $print_timer;

# subscribe to rotator's "set" topic
if ($rot_in_use) {
    $mqtt->subscribe($rotator_set_topic_path . "azimuth",  \&set_azimuth);
    $mqtt->subscribe($rotator_set_topic_path . "elevation", \&set_elevation);
    $mqtt->subscribe($rotator_set_topic_path . "azel", \&set_azimuth_elevation);
    $mqtt->subscribe($rotator_topic_path . "refresh", \&refresh_rotator_state);
}

# subscribe to radio's "set" topic
if ($rig_in_use){
    $mqtt->subscribe($radio_set_topic_path . "frequency",  \&set_freq);
    $mqtt->subscribe($radio_set_topic_path . "mode", \&set_mode);
    $mqtt->subscribe($radio_set_topic_path . "ptt", \&set_ptt);
    $mqtt->subscribe($radio_topic_path . "refresh", \&refresh_radio_state);
}

my $last_azimuth = 0;
my $last_elevation = 0;
my $last_rot_update = [gettimeofday];

while($loop){
    $mqtt->tick();	# check if there are waiting subscribed messages 

    #get data only if rig is in use and connected
    if ($rig_in_use && $rig->{state}->{comm_state}==1 &&(tv_interval($rig_timer) >= $rig_update_interval)){
	$rig_timer = [gettimeofday];
	($freq, $mode, $passband, $ptt, $rig_connected) = get_radio_state($rig);
    }
    #get data only if rotator is in use and connected
    if ($rot_in_use  &&(tv_interval($rot_timer) >= $rot_update_interval)){
	if ($rot->{state}->{comm_state}==1){
	    $rot_timer = [gettimeofday];
	    ($azimuth, $elevation, $direction) = get_rotator_state($rot);
	    
	    # update only if values cahnged or timer expired
	    if (($azimuth != $last_azimuth) || ($elevation != $last_elevation) || (tv_interval($last_rot_update) >= ($rot_update_interval * 3))) {
		mqtt_publish_rotator($azimuth, $elevation, $direction);
		$last_rot_update = $rot_timer;
	    }
	    $rotator_connected 	= $rot->{state}->{comm_state};
	    $last_azimuth = $azimuth;
	    $last_elevation = $elevation;
	} else {
	if ($is_a_service == 1) { die "Rotator disconnected, restart required"; }
	 
	# do reconnect, which does not work
#		rot_close($rot);
#		$rot=rot_open($rotator_type, $rotator_path); 
	    }
    }

    if (!$quiet && (tv_interval($print_timer) >= $print_interval)) {
	$print_timer = [gettimeofday];
        print "Connection states:\n";
	print "Rig / Rotator : $rig_connected / $rotator_connected\n";
	print "Rig / Rot host: $rig->{state}->{rigport}->{pathname}\n";
	print "Frequency     : $freq\n";
	print "Mode/passband : $mode, $passband\n";
	print "PTT           : $ptt\n";
	print "Azimuth/el    : $azimuth ($direction) / $elevation\n";
    }


sleep (0.25);
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

sub get_radio_state(){
    my $rig = shift;
    my $rig_connected 		= $rig->{state}->{comm_state};
    if (!$rig_connected) {return};
    my $freq 			= get_freq($rig);
    my ($mode, $passband) 	= get_mode($rig);
    my $ptt 			= get_ptt($rig);
    mqtt_publish_radio($freq, $mode, $passband, $ptt);
    return($freq, $mode, $passband, $ptt, $rig_connected);
}

sub get_rotator_state(){
    my $rot = shift;
    my $rotator_connected 	= $rot->{state}->{comm_state};
    if (!$rotator_connected) {return};
    my ($azimuth, $elevation)	= get_position($rot);
    my $direction = &azimuth_to_direction($azimuth);
#    mqtt_publish_rotator($azimuth, $elevation, $direction);
    return($azimuth, $elevation, $direction, $rotator_connected);
}

# mqtt refresh event
sub refresh_radio_state(){
    my ($azimuth, $elevation, $direction, $rotator_connected) = &get_radio_state($rig);
# todo    mqtt_publish_radio($freq, $mode, $passband, $ptt);
}

sub refresh_rotator_state(){
    my ($azimuth, $elevation, $direction, $rotator_connected) = &get_rotator_state($rot);
    mqtt_publish_rotator($azimuth, $elevation, $direction);
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

# grazina ptt busena, reikia rig
sub get_ptt{
return shift->get_ptt();
}

sub get_position{
    my ($azimuth, $elevation)= shift->get_position();
    return($azimuth, $elevation);
}

sub is_elevation_valid{
    my $elevation = shift;
    my $is_valid = (($elevation >= $min_elevation) && ($elevation <= $max_elevation));
    if (!$quiet && !$is_valid) { print "elevation $elevation is out of rage\n"; }
    return ($is_valid);
}

sub is_azimuth_valid{
    my $azimuth = shift;
    my $is_valid = (($azimuth >= $min_azimuth) && ($azimuth   <= $max_azimuth));
    if (!$quiet && !$is_valid) { print "azimuth $azimuth is out of rage\n"; }
    return ($is_valid);
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
	if (!$quiet) { print "'$message' is not a digit\n"; }
	return;
    }  
    if (azimuth_is_valid($message)) {
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
    if (elevation_is_valid ($message)) {
	my ($azimuth, $elevation)= $rot->get_position();
	$rot->set_position($azimuth, $message);
    }
}

sub set_azimuth_elevation{
    my ($topic, $message) = @_;
    if (!$quiet) {print "$topic -> $message\n";}
    my ($azimuth, $elevation) = split(/,/, $message);

    if (!defined $elevation || !defined $azimuth) {
	if (!$quiet) { print "setting azimuth and elevation requires two digits separated by comma\n"; }
	return;
    };
 
    if (! ( $azimuth =~ /^-?\d+$/) && ( $elevation =~ /^-?\d+$/) ) {
	if (!$quiet) { print "'$message' is not two digits separated by comma\n"; }
	return;
    }
    if   ( is_elevation_valid($elevation) && is_azimuth_valid($azimuth) )
    {
    if (!$quiet) {print "Moving antenna to az/el: $azimuth/$elevation\n";}
	$rot->set_position($azimuth, $elevation);
    }
}


#set rig frequency
sub set_freq(){
    my ($topic, $message) = @_;
    if (!$quiet) {print "$topic -> $message\n";}
    if (!( $message =~ /^-?\d+$/)) {
        if (!$quiet) { print "'$message' is not a digit\n"; }
        return;
    }
    if ((($message >= $min_vhf_frequency) && ($message <= $max_vhf_frequency)) ||
        (($message >- $min_uhf_frequency) && ($message <= $max_vhf_frequency)))
    {
        $rig->set_freq($Hamlib::RIG_VFO_CURR, $message);
    }
}

#set rig mode and passband
sub set_mode(){
    my ($topic, $message) = @_;
    my $nmode;
    my $npassband;
    if (!$quiet) {print "$topic -> $message\n";}
    if (! ($message =~ /^(AM|FM|CW|CWR|USB|LSB)$/i ) ) {
        if (!$quiet) { 
            print "'$message' is not a valid mode.";
        }
        return;
    }
    $message = uc $message;
    
    if ($message eq 'AM') { $nmode = $Hamlib::RIG_MODE_AM; }
    elsif ($message eq 'FM') { $nmode = $Hamlib::RIG_MODE_FM; }
    elsif ($message eq 'CW') { $nmode = $Hamlib::RIG_MODE_CW; }
    elsif ($message eq 'CWR') { $nmode = $Hamlib::RIG_MODE_CWR; }
    elsif ($message eq 'LSB') { $nmode = $Hamlib::RIG_MODE_LSB; }
    elsif ($message eq 'USB') { $nmode = $Hamlib::RIG_MODE_USB; }
    else { $nmode = $Hamlib::RIG_MODE_FM; }
    $rig->set_mode($nmode, $rig->passband_normal($nmode) );
}

#set ptt to on or off
sub set_ptt(){
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
