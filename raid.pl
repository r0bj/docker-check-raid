#!/usr/bin/perl

use strict;
use warnings;
eval 'use Parse::HP::ACU';

my $twcli = '/usr/local/sbin/tw_cli';
my $megactl = '/usr/local/sbin/megactl';
my $mdadm = '/sbin/mdadm';
my $megacli = '/usr/local/sbin/MegaCli64';
my $cciss_vol_status = '/usr/bin/cciss_vol_status';

my $battery_check = 0;
my $cache_check = 0;

my @tmp;
my @output;

sub three_ware {
	my @c;

	foreach (`$twcli info`) {
		push(@c,$1) if ($_ =~ /^(c[0-9]+).*/);
	}

	foreach my $c (@c) {
		foreach (`$twcli info $c`) {
			if (/^(u\d+)\s+\S+\s+(\S+)\s+(\d+%)?(?:\S+)?\s+(\d+%)?/) {
				if ($2 eq 'REBUILDING' || $2 eq 'REBUILD-INIT' || $2 eq 'DEGRADED-RBLD') {
					push (@output, lc ($c.$1.":".$2."(".$3.")"));
				} elsif ($2 eq 'VERIFYING' || $2 eq 'INITIALIZING') {
					push (@output, lc ($c.$1.":".$2."(".$4.")"));
				} else {
					push (@output, lc ($c.$1.":".$2));
				}
			} 
		}
	}
}

sub lsi {
	my ($a, $v, $e, $s);
	my (%lsi, %state, %out, @output_tmp);

	my $cache_cade = 0;
	# filling hash with data from controller - classify whole adapter as 'optimal' or not
	foreach (`$megacli -LDInfo -lALL -aALL -NoLog`) {
		$a = $1 if /^Adapter\s+(\d+)/;
		$v = $1 if /^Virtual\sDrive(?:\s+)?:\s+(\d+)/;
		$state{$a}{$v}{'consistency-check'} = $1 if /^\s+Check\sConsistency(?:.*)Completed\s(\d+%),/;
		$state{$a}{$v}{'background-init'} = $1 if /^\s+Background\sInitialization(?:.*)Completed\s(\d+%),/;
		if ($_ =~ /^State(?:\s+)?:\s+Optimal/) {
			$state{$a}{$v}{'state'} = 'optimal';
		} elsif ($_ =~ /^State(?:\s+)?:\s+\S+/) {
			$lsi{$a} = {};
		} elsif ($_ =~ /^CacheCade Virtual Drive:\s+\d+/) {
			$lsi{$a} = {};
		}

		if ($cache_check) {
			# cache policy check only if present outside cache cade section
			$cache_cade = 1 if /^CacheCade Virtual Drive:/;
			$cache_cade = 0 if ($cache_cade == 1 && $_ =~ /^\s+$/);
			if ($cache_cade != 1) {
				if ($_ =~ /^Current Cache Policy:\s+(.*)/ && $1 ne 'WriteBack, ReadAhead, Cached, No Write Cache if Bad BBU') {
					push (@output_tmp, lc ('a'.$a.'d'.$v.':cache-policy:wrong'));
				}
				if ($_ =~ /^Disk Cache Policy\s+:\s+(.*)/ && $1 ne 'Enabled') {
					if ($1 eq "Disk's Default") {
						push (@output_tmp, lc ('a'.$a.'d'.$v.':disk-cache-policy:disks-default'));
					}
					else {
						push (@output_tmp, lc ('a'.$a.'d'.$v.':disk-cache-policy:'.$1));
					}
				}
			}
		}
	}

	# fast mode - output data with positive status if adapter is not classified as 'optimal'
	foreach my $a (keys %state) {
		if (!exists ($lsi{$a})) {
			foreach my $v (keys %{$state{$a}}) {
				my $ongoing_proc = 0;
				if (exists $state{$a}{$v}{'consistency-check'}) {
					push (@output,lc("a".$a."d".$v.":consistency-check($state{$a}{$v}{'consistency-check'})"));
					$ongoing_proc = 1;
				}
				if (exists $state{$a}{$v}{'background-init'}) {
					push (@output,lc("a".$a."d".$v.":background-init($state{$a}{$v}{'background-init'})"));
					$ongoing_proc = 1;
				}
				if (!$ongoing_proc) {
					push (@output,lc("a".$a."d".$v.":ok"));
				}
			}
		}
	}

	# detailed mode - filling hash with data from controller classified as not 'optimal'
	foreach my $a (keys %lsi) {
		foreach (`$megacli -LDPDInfo -a$a -NoLog`) {
			$v = $1 if /^(?:CacheCade\s+)?Virtual Drive(?:\s+)?:\s+(\d+)/;
			$lsi{$a}{$v}{'consistency-check'} = $1 if /^\s+Check\sConsistency(?:.*)Completed\s(\d+%),/;
			$lsi{$a}{$v}{'background-init'} = $1 if /^\s+Background\sInitialization(?:.*)Completed\s(\d+%),/;
			$lsi{$a}{$v}{'state'} = $1 if /^State\s+:\s+(.*)/;
			$lsi{$a}{$v}{'state'} = 'partially-degraded' if /^State\s+:\s+Partially\sDegraded/;
			$e = $1 if /^Enclosure Device ID:\s+(\d+)/;
			$s = $1 if /Slot Number:\s+(\d+)/;
			$lsi{$a}{$v}{'enclosure'}{$e}{$s}{'state'} = $1 if /^Firmware state:\s+(.+)/;
		}
	}

	# filling output hash
	foreach my $a (keys %lsi) {
		foreach my $v (keys %{$lsi{$a}}) {
			if ($lsi{$a}{$v}{'state'} && $lsi{$a}{$v}{'state'} ne "Optimal") {
				foreach my $e (keys %{$lsi{$a}{$v}{'enclosure'}}) {
					foreach my $s (keys %{$lsi{$a}{$v}{'enclosure'}{$e}}) { 
						if ($lsi{$a}{$v}{'enclosure'}{$e}{$s}{'state'} eq "Rebuild") {
							my $proc;
							foreach (`$megacli -PDRbld -ShowProg -PhysDrv[$e:$s] -a$a`) {
								$proc = $1 if /^Rebuild Progress on Device at Enclosure $e, Slot $s Completed (\d+)%/;
							}
							$out{"a".$a}{"d".$v}{"e".$e."s".$s} = lc ($lsi{$a}{$v}{'enclosure'}{$e}{$s}{'state'}.((length $proc) ? "($proc%)" : ''))
						} elsif ($lsi{$a}{$v}{'enclosure'}{$e}{$s}{'state'} ne "Online, Spun Up") {
							$out{"a".$a}{"d".$v}{"e".$e."s".$s} = lc ($lsi{$a}{$v}{'enclosure'}{$e}{$s}{'state'})
						}
					}
				}
			}
			if ($lsi{$a}{$v}{'consistency-check'}) {
				$out{"a".$a}{"d".$v}{"d".$v} = lc ("consistency-check($lsi{$a}{$v}{'consistency-check'})" );
			}
			if ($lsi{$a}{$v}{'background-init'}) {
	                        $out{"a".$a}{"d".$v}{"d".$v} = lc ("background-init($lsi{$a}{$v}{'background-init'})" );
	                }
			if ($lsi{$a}{$v}{'state'} && ! keys %{$out{"a".$a}{"d".$v}}) {
				$out{"a".$a}{"d".$v}{"d".$v} = lc (($lsi{$a}{$v}{'state'} eq "Optimal") ? "ok" : $lsi{$a}{$v}{'state'});
			}
		}
	}

	# output data from output hash
	foreach my $a (sort keys %out) {
		foreach my $v (sort keys %{$out{$a}}) {
			foreach my $item (sort keys %{$out{$a}{$v}}) {
				push (@output,lc ($a.$item.":".$out{$a}{$v}{$item}));
			}
		}
	}

	if ($battery_check) {
		undef $a;
		# battery check
		foreach (`$megacli -AdpBbuCmd -aALL -NoLog`) {
			$a = $1 if /^BBU status for Adapter:\s+(\d+)/;
			if (length $a && $_ =~ /^Battery State\s*:\s+(.*)/ && $1 ne 'Operational' && $1 ne 'Optimal') {
				if ($1 eq 'Non Operational') {
					push (@output, lc ('a'.$a.':battery:non-operational'));
				}
				else {
					push (@output, lc ('a'.$a.':battery:'.$1));
				}
			}
			if ($_ =~ /^Adapter (\d+): Get BBU Status Failed./) {
				push (@output, lc ('a'.$1.':battery:fail'));
			}
		}
	}

	if (@output_tmp) {
		push (@output, @output_tmp);
	}
}

sub lsi_megactl {
	foreach (`$megactl 2>/dev/null`) {
		if ($_ =~ /^(a[0-9]+d[0-9]+)\s+\w+\s+\w+\s+\w+\s+\w+\s+(\w+)$/) {
			push(@output,lc($1.":".(($2 eq "optimal") ? "ok" : $2)));
		}
	}
}

sub softraid {
	my $md;
	my %mds;

	foreach (`cat /proc/mdstat`) {
		if ($_ =~ /^(md[0-9]+)\s+:\s+/) {
			$md = $1;
			next;
		}
		if ($_ =~ /^\s+[0-9]+\s+\w+\s+(?:\w+\s+[\d\.]+\s+)?\[[0-9\/]+\]\s+\[(\w+)\]/) {
			if ($1 =~ /^U+$/) {
				$mds{$md} = {'status' => 'ok'};
			}
			else {
				$mds{$md} = {'status' => 'degraded'};
			}
			next;
		}
		if ($_ =~ /^\s+\[[=>\.]+\]\s+recovery\s+=\s+(\d+)(?:\.\d+)?%/) {
			$mds{$md}{'rebuilding'} = $1.'%';
			next;
		}
	}

	foreach my $md (sort keys %mds) {
		if ($mds{$md}{'status'} eq 'ok') {
			push (@output, lc ($md.":ok"));
		}
		else {
			if (exists $mds{$md}{'rebuilding'}) {
				push (@output, lc ($md.":rebuilding(".$mds{$md}{'rebuilding'}.")"));
			}
			else {
				push (@output, lc ($md.":degraded"));
			}
		}
	}
}

sub hp {
	my $hp = 0;
	if ( -c "/dev/sg0" ) {
		opendir (my $dh, "/dev/");
		my @devs = grep { /^sg\d+$/ } readdir($dh);

		foreach my $dev (@devs) {
			foreach (`$cciss_vol_status -V /dev/$dev 2>/dev/null`) {
				if (/^Controller:/) {
					$hp = 1;
					last;
				}
			}
			last if $hp;
		}
	}

	if ($hp) {
		my $acu = Parse::HP::ACU->new();
		my $ctrls = $acu->parse_config();

		foreach my $slot (keys %$ctrls) {
			foreach my $array (keys %{$ctrls->{$slot}->{'array'}}) {
				foreach my $ld (keys %{$ctrls->{$slot}->{'array'}->{$array}->{'logical_drive'}}) {
					my $disk = $1 if ($ctrls->{$slot}->{'array'}->{$array}->{'logical_drive'}->{$ld}->{'disk_name'} =~ /\/dev\/(\S+)$/);
					$disk = "ld$ld" if (! $disk);

					if ($ctrls->{$slot}->{'array'}->{$array}->{'logical_drive'}->{$ld}->{'status'} =~ /^Recovering, (\d+)% complete$/) {
						my $ld_status = "rebuilding($1%)";
						push (@output, lc ($disk.":".$ld_status));
					}
					elsif ($ctrls->{$slot}->{'array'}->{$array}->{'logical_drive'}->{$ld}->{'status'} =~ /^Interim Recovery Mode$/) {
						push (@output, lc ($disk.":degraded"));
					}
					else {
						(my $ld_status = $ctrls->{$slot}->{'array'}->{$array}->{'logical_drive'}->{$ld}->{'status'}) =~ s/ /_/g;
						push (@output, lc ($disk.":".$ld_status));
					}
				}
				foreach my $pd (keys %{$ctrls->{$slot}->{'array'}->{$array}->{'physical_drive'}}) {
					if ($ctrls->{$slot}->{'array'}->{$array}->{'physical_drive'}->{$pd}->{'status'} ne "OK") {
						(my $display_pd = $pd) =~ s/:/-/g;
						(my $pd_status = $ctrls->{$slot}->{'array'}->{$array}->{'physical_drive'}->{$pd}->{'status'}) =~ s/ /-/g;
						push (@output, lc ("disk:$display_pd:".$pd_status));
					}
				}
			}
		}
	}
}

## MAIN

three_ware () if (-e $twcli);
lsi () if (-e $megacli);
lsi_megactl () if (-e $megactl);
softraid () if (-e $mdadm);
hp () if (-e $cciss_vol_status);

print join('|', @output)."\n";
