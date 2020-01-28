package main;

use strict;
use warnings;
use Text::Balanced qw ( extract_codeblock extract_delimited );

use Data::Dumper;

use constant {
	ATTRIBUTE_PUBLISH 		=>	'MQTT2_Legacy'
};

sub MQTT2_Legacy_Initialize {
	my ($hash) = @_;

	addToAttrList("${ \ATTRIBUTE_PUBLISH }:textField-long");

	$hash->{DefFn}				= "MQTT2_Legacy_Define";
	$hash->{UndefFn}			= "MQTT2_Legacy_Undef";
	$hash->{SetFn}				= "MQTT2_Legacy_Set";
	$hash->{NotifyFn}			= "MQTT2_Legacy_Notify";
	$hash->{AttrList}			= "IODev $readingFnAttributes "; 
	$hash->{NotifyOrderPrefix}	= "99-"; #let others do their job first
};

sub MQTT2_Legacy_Define {
	my ($hash, $def) = @_;
	my ($name, $type, $io) = split /\s/, $def;

	$hash->{'Device'} = {};
	$hash->{'storage'}->{'io'} = $io;

	MQTT2_Legacy_Run($hash) if ($init_done);
	return undef;
};

sub MQTT2_Legacy_Run {
	my ($hash) = @_;
	my $io = $hash->{'storage'}->{'io'};

	if ($io and exists($defs{$io}) and $defs{$io}{'TYPE'} =~ m/^MQTT2_SERVER|MQTT2_CLIENT$/o) {
		AssignIoPort($hash, 'mqtt');
		Log3 ($hash->{'NAME'}, 3, sprintf ('[%s] io \'%s\' ready', $hash->{'NAME'}, $io));
	} else {
		Log3 ($hash->{'NAME'}, 1, sprintf ('[%s] MQTT server or client \'%s\' not found', $hash->{'NAME'}, $io));
	};
	return undef;
};

sub MQTT2_Legacy_Set {
	my ($hash, $name, $cmd, @args) = @_;

	return undef;
};

sub MQTT2_Legacy_DeviceCfg {
	my ($hash, $deviceName) = @_;
	my @result;

	if (my $p = AttrVal($deviceName, ATTRIBUTE_PUBLISH, undef)) {
		my $syntax = 1;
		while ($p) {
			my ($d, $e, $t, $v, $f) = (undef, undef, undef, undef, '');
			$syntax &&= (($p =~ s/\s*(publish)\s*:\s*//i) and ($d = $1) and 1);
			($e = extract_codeblock($p, '{}')) or ($e = extract_delimited($p, qw( "' )));
			$syntax &&= (defined($e) and length($e) and $p =~ s/^\s*,{1}\s*//);
			($t = extract_codeblock($p, '{}')) or ($t = extract_delimited($p, qw( "' )));
			$syntax &&= (defined($t) and length($t) and $p =~ s/^\s*,{1}\s*//);
			($v = extract_codeblock($p, '{}')) or ($v = extract_delimited($p, qw( "' )));
			$syntax &&= (defined($v) and length($v) and 1);
			# optional flags
			if ($p =~ s/^\s*,{1}\s*//) {
				$syntax &&= (($p =~ s/(.+?);\s*//) and ($f = $1) and 1);
			} else {
				$syntax &&= $p =~ s/^\s*;{1}\s*//;
			};
			if ($syntax) {
				push @result, {
					'pusub'	=> $d,
					'event'	=> $e,
					'topic'	=> $t,
					'value'	=> $v,
					'flags'	=> $f
				};
			} else {
				Log3 ($deviceName, 2, sprintf ('[%s] error in attribute \'%s\', here: %s', $deviceName, +ATTRIBUTE_PUBLISH, substr($p||'', 0, 40)));
				return undef;
			};
		};
		return \@result;
	};
	return undef;
};

sub MQTT2_Legacy_Notify {
	my ($hash, $dev) = @_;
	my $name = $hash->{'NAME'};
	return undef if(IsDisabled($name));

	my $events = deviceEvents($dev, 1);
	return if(!$events);

	foreach my $event (@{$events}) {
		my @e = split /\s/, $event;
		Log3 ($name, 3, sprintf('[%s] event:[%s], device:[%s]', $name, $event, $dev->{'NAME'}));
		if ($dev->{'TYPE'} eq 'Global') {
			if ($e[0] and $e[0] eq 'INITIALIZED') {
				MQTT2_Legacy_Run($hash);
			} elsif ($e[0] and $e[0] eq 'ATTR' and $e[2] eq ATTRIBUTE_PUBLISH) {
				# The attribute has been altered, delete the device.
				# It will be learned from scratch afterwards if needed
				if ($e[1] and exists($hash->{'Device'}->{$e[1]})) {
					delete($hash->{'Device'}->{$e[1]});
				};
			};
		};

		# if we dont know that device - learn it
		if (not exists($hash->{'Device'}->{$dev->{'NAME'}})) {
			if (AttrVal($dev->{'NAME'}, ATTRIBUTE_PUBLISH, undef)) {
				if (my $r = MQTT2_Legacy_DeviceCfg($hash, $dev->{'NAME'})) {
					$hash->{'Device'}->{$dev->{'NAME'}}->{'PublishCfg'} = $r;
				};
			};
		};

		# device not aimed to publish, skip
		next if (not $hash->{'Device'}->{$dev->{'NAME'}}->{'PublishCfg'});

		my $NAME 	= $dev->{'NAME'};
		my $TYPE 	= $dev->{'TYPE'};
		my $ALIAS	= AttrVal($NAME, 'alias', undef)||$NAME;

		my $cv = '';
		for (my $i=0; $i<scalar(@e); $i++) {
			$cv .= "my \$EVTPART$i = \$e[$i];";
		};

		# remove trailing colon if present
		my $EVT		= shift @e; $EVT =~ s/:$//;
		my $VAL 	= join(' ', @e)||'N/A';

		# if we dont know that event - learn it
		if (not exists($hash->{'Device'}->{$dev->{'NAME'}}->{'PublishSet'}->{$EVT})) {
			my @actions;
			foreach my $cfg (@{$hash->{'Device'}->{$dev->{'NAME'}}->{'PublishCfg'}}) {
				# skip if its not a publish
				next if (defined($cfg->{'pusub'}) and not ($cfg->{'pusub'} eq 'publish'));
				my $m = eval $cv."$cfg->{'event'};";
				if (eval { $EVT =~ /^$m$/ }) {
					push @actions, $cfg;
				};
				$hash->{'Device'}->{$dev->{'NAME'}}->{'PublishSet'}->{$EVT} = \@actions;
			};
		};

		# finish here if that event is not aimed to be published
		next if (not my $actions = $hash->{'Device'}->{$dev->{'NAME'}}->{'PublishSet'}->{$EVT});

		my sub Reading {
			my ($reading) = @_;
			ReadingsVal($NAME, $reading, 'N/A');
		};

		my sub Internal {
			my ($internal) = @_;
			InternalVal($NAME, $internal, 'N/A');
		};

		my sub Json {
			my $object = {};
			foreach my $reading (@_) {
				$object->{$reading} = ReadingsVal($NAME, $reading, 'N/A');
			};
			MQTT2_Convert::JSON::StreamWriter->new()->parse($object);
		};

		my sub JsonObject {
			my ($object) = @_;
			MQTT2_Convert::JSON::StreamWriter->new()->parse($object);
		};

		my sub LogError {
			my ($error) = @_;
			# remove useless parts
			$error =~ s/requires explicit package name \(did you forget to declare .*/is unknown/s;
			$error =~ s/\sat \(eval.*//s;
			Log3 ($NAME, 2, sprintf('[%s] error in attribute \'%s\': %s', $NAME, +ATTRIBUTE_PUBLISH, $error));
			return undef;
		};

		foreach my $action (@$actions) {
			# printf "event:[%s],topic:[%s],value:[%s]\n", $EVT, $action->{'topic'}, $action->{'value'};
			my ($t, $v, $syntax) = (undef, undef, 1);
			$syntax &&= (($t = eval $cv.$action->{'topic'}) or LogError($@));
			$syntax &&= (($v = eval $cv.$action->{'value'}) or LogError($@));
			IOWrite($hash, "publish", "$t $v");
			Log3 ($NAME, 3, sprintf('[%s] publish topic:[%s], value:[%s], flags:[%s]', $NAME, $t, $v, $action->{'flags'})) if ($syntax);
		};
	};
	return undef;
};

package MQTT2_Convert::JSON::StreamWriter;

use strict;
use warnings;
use utf8;
use B;

my ($escape, $reverse);

BEGIN {
	%{$escape} =  (
		'"'     => '"',
		'\\'    => '\\',
		'/'     => '/',
		'b'     => "\x08",
		'f'     => "\x0c",
		'n'     => "\x0a",
		'r'     => "\x0d",
		't'     => "\x09",
		'u2028' => "\x{2028}",
		'u2029' => "\x{2029}"
	);
	%{$reverse} = map { $escape->{$_} => "\\$_" } keys %{$escape};
	for(0x00 .. 0x1f) {
		my $packed = pack 'C', $_;
		$reverse->{$packed} = sprintf '\u%.4X', $_ unless defined $reverse->{$packed};
	};
};

sub new {
	my $class = shift;
	my $self = {};
	bless $self, $class;
	return $self;
};

sub parse {
	my ($self, $data) = @_;
	my $stream;

	if (my $ref = ref $data) {
		use Encode;
		return Encode::encode_utf8($self->addValue($data));
	};
};

sub addValue {
	my ($self, $data) = @_;
	if (my $ref = ref $data) {
		return $self->addONode($data) if ($ref eq 'HASH');
		return $self->addANode($data) if ($ref eq 'ARRAY');
	};
	return 'null' unless defined $data;
	return $data
		if B::svref_2object(\$data)->FLAGS & (B::SVp_IOK | B::SVp_NOK)
		# filter out "upgraded" strings whose numeric form doesn't strictly match
		&& 0 + $data eq $data
		# filter out inf and nan
		&& $data * 0 == 0;
	# String
	return $self->addString($data);
};

sub addString {
	my ($self, $str) = @_;
	$str =~ s!([\x00-\x1f\x{2028}\x{2029}\\"/])!$reverse->{$1}!gs;
	return "\"$str\"";
};

sub addONode {
	my ($self, $object) = @_;
	my @pairs = map { $self->addString($_) . ':' . $self->addValue($object->{$_}) }
		sort keys %$object;
	return '{' . join(',', @pairs) . '}';
};

sub addANode {
	my ($self, $array) = @_;
	return '[' . join(',', map { $self->addValue($_) } @{$array}) . ']';
};

# static, sanitize a json message

1;
