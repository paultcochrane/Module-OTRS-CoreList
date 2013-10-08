#!/usr/bin/perl

use strict;
use warnings;

use Archive::Tar;
use Clone qw(clone);
use Data::Dumper;
use File::Spec;
use File::Temp;
use Net::FTP;

my $ftp_host  = 'ftp.otrs.org';
my $local_dir = File::Temp::tempdir();
my @dirs      = qw(pub otrs);

my $ftp = Net::FTP->new( $ftp_host, Debug => 0 );
$ftp->login();

for my $dir ( @dirs ) {
    $ftp->cwd( $dir );
}

my @files   = $ftp->ls;
my @tar_gz  = grep{ m{ \.tar\.gz \z }xms }@files;
my @no_beta = grep{ !m{ -beta }xms }@tar_gz;

my %global;
my %hash;

my $flag = 0;

FILE:
for my $file ( @no_beta ) {
    my ($major,$minor,$patch) = $file =~ m{ \A otrs - (\d+) \. (\d+) \. (\d+) \.tar\.gz  }xms;
    
    next FILE if !(defined $major and defined $minor);
    
    next FILE if $major < 2;
    next FILE if $major == 2 and $minor < 3;
    
    print STDERR "Try to get $file\n";
    
    my $local_path = File::Spec->catfile( $local_dir, $file );
    
    $ftp->binary;
    $ftp->get( $file, $local_path );
    
    my $tar              = Archive::Tar->new( $local_path, 1 );
    my @files_in_archive = $tar->list_files;
    my @modules          = grep{ m{ \.pm \z }xms }@files_in_archive;
    
    my $version = '';
    
    MODULE:
    for my $module ( @modules ) {
        next MODULE if $module =~ m{/scripts/};
    
        my ($otrs,$modfile) = $module =~ m{ \A otrs-(\d+\.\d+\.\d+)/(.*) }xms;

        next MODULE if !$modfile;

        my $is_cpan = $modfile =~ m{cpan-lib}xms;
        
        my $key = $is_cpan ? 'cpan' : 'core';

        next MODULE if !$modfile;
        
        (my $modulename = $modfile) =~ s{/}{::}g;

        next MODULE if !$modulename;

        $modulename =~ s{\.pm}{}g;
        $modulename =~ s{Kernel::cpan-lib::}{}g if $is_cpan;
        
        $version = $otrs;

        next MODULE if !$otrs;
        next MODULE if !$modulename;
        
        $hash{$otrs}->{$key}->{$modulename} = 1;
    }
    
    if ( !$flag ) {
        %global = %{ clone( $hash{$version} ) };
    }
    else {
        for my $type ( keys %{ $hash{$version} } ) {
            for my $modulename ( keys %{ $hash{$version}->{$type} } ) {
                $global{$type}->{$modulename}++;
            }
        }
    }
    
    $flag++;
}

$flag--;

# check if modules could stay in global hash
my @to_delete;
for my $type ( keys %global ) {
    for my $modulename ( keys %{ $global{$type} } ) {
        if ( $global{$type}->{$modulename} < $flag ) {
            delete $global{$type}->{$modulename};
        }
        else {
            push @to_delete, $modulename;
        }
    }
}

# delete modules that are stored in global hash
for my $otrs_version ( keys %hash ) {
    for my $type ( keys %{ $hash{$otrs_version} } ) {
        delete @{ $hash{$otrs_version}->{$type} }{@to_delete};
    }
}

$Data::Dumper::Sortkeys = 1;

if ( open my $fh, '>', 'corelist' ) {
    print $fh q~package Module::OTRS::CoreList;

use strict;
use warnings;

# ABSTRACT: what modules shipped with versions of OTRS (>= 2.3.x)

=head1 SYNOPSIS

 use Module::OTRS::CoreList;

 my @otrs_versions = Module::OTRS::CoreList->shipped(
    '2.4.x',
    'Kernel::System::DB',
 );
 
 # returns (2.4.0, 2.4.1, 2.4.2,...)
 
 my @modules = Module::OTRS::CoreList->modules( '2.4.8' );
 my @modules = Module::OTRS::CoreList->modules( '2.4.x' );
 
 # methods to check for CPAN modules shipped with OTRS
 
 my @cpan_modules = Module::OTRS::CoreList->cpan_modules( '2.4.x' );

 my @otrs_versions = Module::OTRS::CoreList->shipped(
    '3.0.x',
    'CGI',
 );

=cut

~;

    print $fh "\n\n";

    my $global_dump = Data::Dumper->Dump( [\%global], ['global'] );
    $global_dump =~ s{\$global}{my \$global};
    print $fh $global_dump;

    print $fh "\n";

    my $modules_dump = Data::Dumper->Dump( [\%hash], ['modules'] );
    $modules_dump =~ s{\$modules}{my \$modules};
    print $fh $modules_dump;

    print $fh "\n\n";

    print $fh q#sub shipped {
    my ($class,$version,$module) = @_;

    return if !$version;
    return if $version !~ m{ \A [0-9]+\.[0-9]\.(?:[0-9]+|x) \z }xms;

    $version =~ s{\.}{\.}g;
    $version =~ s{x}{.*};

    my $version_re = qr{ \A $version \z }xms;

    my @versions_with_module;

    OTRSVERSION:
    for my $otrs_version ( sort keys %{$modules} ) {
        next unless $otrs_version =~ $version_re;

        if ( $modules->{$otrs_version}->{core}->{$module} ||
             $modules->{$otrs_version}->{cpan}->{$module} ||
             $global->{core}->{$module} ||
             $global->{cpan}->{$module} ) {
            push @versions_with_module, $otrs_version;
        }
    }

    return @versions_with_module;
}

sub modules {
    my ($class,$version) = @_;

    return if !$version;
    return if $version !~ m{ \A [0-9]+\.[0-9]\.(?:[0-9]+|x) \z }xms;

    $version =~ s{\.}{\.}g;
    $version =~ s{x}{.*};

    my $version_re = qr{ \A $version \z }xms;
    my %modules_in_otrs;

    OTRSVERSION:
    for my $otrs_version ( keys %{$modules} ) {
        next unless $otrs_version =~ $version_re;

        my $hashref = $modules->{$otrs_version}->{core};
        my @modulenames = keys %{$hashref || {}};

        @modules_in_otrs{@modulenames} = (1) x @modulenames;
    }

    if ( $version =~ m{x} || exists $modules->{$version} ) {
        my @global_modules = keys %{ $global->{core} };
        @modules_in_otrs{@global_modules} = (1) x @global_modules;
    }

    return sort keys %modules_in_otrs;
}

sub cpan_modules {
    my ($class,$version) = @_;

    return if !$version =~ m{ \A [0-9]+\.[0-9]\.(?:[0-9]+|x) \z }xms;

    $version =~ s{\.}{\.}g;
    $version =~ s{x}{.*};

    my $version_re = qr{ \A $version \z }xms;

    my %modules_in_otrs;

    OTRSVERSION:
    for my $otrs_version ( keys %{ $modules } ) {
        next unless $otrs_version =~ $version_re;

        my $hashref = $modules->{$otrs_version}->{cpan};
        my @modulenames = keys %{$hashref || {}};

        @modules_in_otrs{@modulenames} = (1) x @modulenames;
    }

    if ( $version =~ m{x} || exists $modules->{$version} ) {
        my @global_modules = keys %{ $global->{cpan} };
        @modules_in_otrs{@global_modules} = (1) x @global_modules;
    }

    return sort keys %modules_in_otrs;
}

1;

#;
}
