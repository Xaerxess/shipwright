package Shipwright::Backend::SVN;

use warnings;
use strict;
use Carp;
use File::Spec;
use Shipwright::Util;
use File::Temp qw/tempdir/;
use File::Copy;
use File::Copy::Recursive qw/dircopy/;

our %REQUIRE_OPTIONS = ( import => [qw/source/], );

use base qw/Class::Accessor::Fast/;
__PACKAGE__->mk_accessors(qw/repository log/);

=head2 new

=cut

sub new {
    my $class = shift;
    my $self  = {@_};

    bless $self, $class;
    $self->log( Log::Log4perl->get_logger( ref $self ) );
    return $self;
}

=head2 initialize

initialize a project

=cut

sub initialize {
    my $self = shift;
    my $dir = tempdir( CLEANUP => 1 );
    dircopy( Shipwright::Util->share_root, $dir );

    # share_root can't keep empty dirs, we have to create them manually
    for (qw/dists scripts t/) {
        mkdir File::Spec->catfile( $dir, $_ );
    }

    # hack for share_root living under blib/
    unlink( File::Spec->catfile( $dir, '.exists' ) );

    $self->delete;    # clean repository in case it exists
    $self->log->info( 'initialize ' . $self->repository );
    $self->import(
        source      => $dir,
        comment     => 'create project',
        _initialize => 1,
    );

}

=head2 import

import a dist

=cut

sub import {
    my $self = shift;
    return unless @_;
    my %args = @_;
    my $name = $args{source};
    $name =~ s{.*/}{};

    unless ( $args{_initialize} ) {
        if ( $args{_extra_tests} ) {
            $self->delete("t/extra");
            $self->log->info( "import extra tests to " . $self->repository );
            Shipwright::Util->run(
                $self->_cmd( import => %args, name => $name ) );
        }
        elsif ( $args{build_script} ) {
            if ( $self->info( path => "scripts/$name") && not $args{overwrite} ) {
                $self->log->warn(
"path scripts/$name alreay exists, need to set overwrite arg to overwrite"
                );
            }
            else {
                $self->delete("scripts/$name");
                $self->log->info(
                    "import $args{source}'s scripts to " . $self->repository );
                Shipwright::Util->run(
                    $self->_cmd( import => %args, name => $name ) );
            }
        }
        else {
            if ( $self->info( path => "dists/$name") && not $args{overwrite} ) {
                $self->log->warn(
"path dists/$name alreay exists, need to set overwrite arg to overwrite"
                );
            }
            else {
                $self->delete("dists/$name");
                $self->log->info(
                    "import $args{source} to " . $self->repository );
                $self->_add_to_order( $name );
                $self->version(
                    dist    => $name,
                    version => $args{version},
                );

                Shipwright::Util->run(
                    $self->_cmd( import => %args, name => $name ) );
            }
        }
    }
    else {
        Shipwright::Util->run( $self->_cmd( import => %args, name => $name ) );
    }
}

=head2 export

a wrapper of export cmd of svn
export a project, partly or as a whole

=cut

sub export {
    my $self = shift;
    my %args = @_;
    my $path = $args{path} || '';
    $self->log->info(
        'export ' . $self->repository . "/$path to $args{target}" );
    Shipwright::Util->run( $self->_cmd( export => %args ) );
}

=head2 checkout

a wrapper of checkout cmd of svn
checkout a project, partly or as a whole

=cut

sub checkout {
    my $self = shift;
    my %args = @_;
    my $path = $args{path} || '';
    $self->log->info(
        'export ' . $self->repository . "/$path to $args{target}" );
    Shipwright::Util->run( $self->_cmd( checkout => @_ ) );
}

=head2 commit

a wrapper of commit cmd of svn

=cut

sub commit {
    my $self = shift;
    my %args = @_;
    $self->log->info( 'commit ' . $args{path} );
    Shipwright::Util->run( $self->_cmd( commit => @_ ), 1 );
}

# a cmd generating factory
sub _cmd {
    my $self = shift;
    my $type = shift;
    my %args = @_;
    $args{path}    ||= '';
    $args{comment} ||= '';

    for ( @{ $REQUIRE_OPTIONS{$type} } ) {
        croak "$type need option $_" unless $args{$_};
    }

    my $cmd;

    if ( $type eq 'checkout' ) {
        $cmd =
          [ 'svn', 'checkout', $self->repository . $args{path}, $args{target} ];
    }
    elsif ( $type eq 'export' ) {
        $cmd =
          [ 'svn', 'export', $self->repository . $args{path}, $args{target} ];
    }
    elsif ( $type eq 'import' ) {
        if ( $args{_initialize} ) {
            $cmd = [
                'svn',         'import',
                $args{source}, $self->repository,
                '-m',          q{'} . $args{comment} . q{'}
            ];
        }
        elsif ( $args{_extra_tests} ) {
            $cmd = [
                'svn', 'import',
                $args{source}, join( '/', $self->repository, 't', 'extra' ),
                '-m', q{'} . $args{comment} . q{'},
            ];
        }
        else {
            if ( my $script_dir = $args{build_script} ) {
                $cmd = [
                    'svn',       'import',
                    $script_dir, $self->repository . "/scripts/$args{name}/",
                    '-m',        q{'} . $args{comment} || '' . q{'},
                ];
            }
            else {
                $cmd = [
                    'svn',         'import',
                    $args{source}, $self->repository . "/dists/$args{name}",
                    '-m',          q{'} . $args{comment} . q{'},
                ];
            }
        }
    }
    elsif ( $type eq 'commit' ) {
        $cmd =
          [ 'svn', 'commit', '-m', q{'} . $args{comment} . q{'}, $args{path} ];
    }
    elsif ( $type eq 'delete' ) {
        $cmd = [
            'svn', 'delete', '-m', q{'} . 'delete' . $args{path} . q{'},
            join '/', $self->repository, $args{path}
        ];
    }
    elsif ( $type eq 'info' ) {
        $cmd = [ 'svn', 'info', join '/', $self->repository, $args{path} ];
    }
    elsif ( $type eq 'propset' ) {
        $cmd = [
            'svn',       'propset',
            $args{type}, q{'} . $args{value} . q{'},
            $args{path}
        ];
    }
    else {
        croak "invalid command: $type";
    }

    return $cmd;
}

# add a dist to order

sub _add_to_order {
    my $self = shift;
    my $name = shift;

    my $order = $self->order;

    unless ( grep { $name eq $_ } @$order ) {
        $self->log->info( "add $name to order for " . $self->repository );
        push @$order, $name;
        $self->order($order);
    }
}

=head2 update_order

regenate order

=cut

sub update_order {
    my $self = shift;
    my %args = @_;
    $self->log->info( "update order for " . $self->repository );

    my @dists = @{ $args{for_dists} || [] };
    unless (@dists) {
        my ($out) = Shipwright::Util->run(
            [ 'svn', 'ls', $self->repository . '/scripts' ] );
        my $sep = $/;
        @dists = split /$sep/, $out;
        chomp @dists;
        s{/$}{} for @dists;
    }

    my $require = {};

    for (@dists) {
        $self->_fill_deps( %args, require => $require, dist => $_ );
    }

    require Algorithm::Dependency::Ordered;
    require Algorithm::Dependency::Source::HoA;

    my $source = Algorithm::Dependency::Source::HoA->new($require);
    $source->load();
    my $dep = Algorithm::Dependency::Ordered->new( source => $source, )
      or die $@;
    my $order = $dep->schedule_all();
    $self->order($order);
}

sub _fill_deps {
    my $self    = shift;
    my %args    = @_;
    my $require = $args{require};
    my $dist    = $args{dist};

    my ($string) = Shipwright::Util->run(
        [ 'svn', 'cat', $self->repository . "/scripts/$_/require.yml" ], 1 );

    my $req = Shipwright::Util::Load($string) || {};

    if ( $req->{requires} ) {
        for (qw/requires recommends build_requires/) {
            push @{ $require->{$dist} }, keys %{ $req->{$_} }
              if $args{"keep_$_"};
        }
    }
    else {

        #for back compatbility
        push @{ $require->{$dist} }, keys %$req;
    }

    for my $dep ( @{ $require->{$dist} } ) {
        next if $require->{$dep};
        $self->_fill_deps( %args, dist => $dep );
    }
}

=head2 order

get or set order

=cut

sub order {
    my $self  = shift;
    my $order = shift;
    if ($order) {
        my $dir = tempdir( CLEANUP => 1 );
        my $file = File::Spec->catfile( $dir, 'order.yml' );

        $self->checkout(
            path   => '/shipwright',
            target => $dir,
        );

        Shipwright::Util::DumpFile( $file, $order );
        $self->commit( path => $file, comment => "set order" );

    }
    else {
        my ($out) = Shipwright::Util->run(
            [ 'svn', 'cat', $self->repository . '/shipwright/order.yml' ] );
        return Shipwright::Util::Load($out);
    }
}

=head2 map

get or set map

=cut

sub map {
    my $self = shift;
    my $map  = shift;
    if ($map) {
        my $dir = tempdir( CLEANUP => 1 );
        my $file = File::Spec->catfile( $dir, 'map.yml' );

        $self->checkout(
            path   => '/shipwright',
            target => $dir,
        );

        Shipwright::Util::DumpFile( $file, $map );
        $self->commit( path => $file, comment => "set map" );

    }
    else {
        my ($out) = Shipwright::Util->run(
            [ 'svn', 'cat', $self->repository . '/shipwright/map.yml' ] );
        return Shipwright::Util::Load($out);
    }
}

=head2 source

get or set source

=cut

sub source {
    my $self   = shift;
    my $source = shift;
    if ($source) {
        my $dir = tempdir( CLEANUP => 1 );
        my $file = File::Spec->catfile( $dir, 'source.yml' );

        $self->checkout(
            path   => '/shipwright',
            target => $dir,
        );

        Shipwright::Util::DumpFile( $file, $source );
        $self->commit( path => $file, comment => "set source" );

    }
    else {
        my ($out) = Shipwright::Util->run(
            [ 'svn', 'cat', $self->repository . '/shipwright/source.yml' ] );
        return Shipwright::Util::Load($out);
    }
}

=head2 delete

wrapper of delete cmd of svn

=cut

sub delete {
    my $self = shift;
    my $path = shift || '';
    if ( $self->info( path => $path) ) {
        $self->log->info( "delete " . $self->repository . "/$path" );
        Shipwright::Util->run( $self->_cmd( delete => path => $path ), 1 );
    }
}

=head2 info

wrapper of info cmd of svn

=cut

sub info {
    my $self = shift;
    my %args = @_;
    my $path = $args{path};

    my ( $info, $err ) =
      Shipwright::Util->run( $self->_cmd( info => path => $path ), 1 );
    if ($err) {
        $err =~ s/\s+$//;
        $self->log->warn($err);
        return;
    }
    return $info;
}

=head2 propset

wrapper of propset cmd of svn

=cut

sub propset {
    my $self = shift;
    my %args = @_;
    my $dir  = tempdir( CLEANUP => 1 );

    $self->checkout( target => $dir, );
    Shipwright::Util->run(
        $self->_cmd(
            propset => %args,
            path => File::Spec->catfile( $dir, $args{path} )
        )
    );

    $self->commit(
        path    => File::Spec->catfile( $dir, $args{path} ),
        comment => "set prop $args{type}"
    );
}

=head2 test_script

set test_script for a project, aka. udpate t/test script

=cut

sub test_script {
    my $self   = shift;
    my %args   = @_;
    my $script = $args{source};
    croak 'need source option' unless $script;

    my $dir = tempdir( CLEANUP => 1 );

    $self->checkout(
        path   => '/t',
        target => $dir,
    );

    my $file = File::Spec->catfile( $dir, 'test' );

    copy( $args{source}, $file );
    $self->commit( path => $file, comment => "update test script" );
}

=head2 requires
return hashref to require.yml for a dist
=cut

sub requires {
    my $self = shift;
    my $name = shift;

    my ($string) = Shipwright::Util->run(
        [ 'svn', 'cat', $self->repository . "/scripts/$name/require.yml" ], 1 );
    return Shipwright::Util::Load($string) || {};
}

=head2 flags

get or set flags

=cut

sub flags {
    my $self   = shift;
    my %args = @_;

    croak "need dist arg" unless $args{dist};

    if ($args{flags}) {
        my $dir = tempdir( CLEANUP => 1 );
        my $file = File::Spec->catfile( $dir, 'flags.yml' );

        $self->checkout(
            path   => '/shipwright',
            target => $dir,
        );

        my $flags = Shipwright::Util::LoadFile( $file );
        $flags->{$args{dist}} = $args{flags};

        Shipwright::Util::DumpFile( $file, $flags );
        $self->commit( path => $file, comment => "set flags for $args{dist}" );
    }
    else {
        my ($out) = Shipwright::Util->run(
            [ 'svn', 'cat', $self->repository . '/shipwright/flags.yml' ] );
        $out = Shipwright::Util::Load($out) || {};
        return $out->{$args{dist}} || []; 
    }
}

=head2 version

get or set version

=cut

sub version {
    my $self   = shift;
    my %args = @_;

    croak "need dist arg" unless $args{dist};

    if ( exists $args{version} ) {
        my $dir = tempdir( CLEANUP => 1 );
        my $file = File::Spec->catfile( $dir, 'version.yml' );

        $self->checkout(
            path   => '/shipwright',
            target => $dir,
        );

        my $version = Shipwright::Util::LoadFile( $file );
        $version->{$args{dist}} = $args{version};

        Shipwright::Util::DumpFile( $file, $version );
        $self->commit( path => $file, comment => "set version for $args{dist}" );
    }
    else {
        my ($out) = Shipwright::Util->run(
            [ 'svn', 'cat', $self->repository . '/shipwright/version.yml' ] );
        $out = Shipwright::Util::Load($out) || {};
        return $out->{$args{version}}; 
    }
}

=head2 versions

get versions

=cut

sub versions {
    my $self = shift;

    my ($out) = Shipwright::Util->run(
        [ 'svn', 'cat', $self->repository . '/shipwright/version.yml' ] );
    $out = Shipwright::Util::Load($out) || {};
    return $out;
}

=head2 check_repository

=cut

sub check_repository {
    my $self = shift;
    my %args = @_;

    if ( $args{action} eq 'create' ) {

            my $info = $self->info;

            return 1 if $info;

    }
    else {

        # every valid shipwright repo has 'shipwright' subdir;
        my $info = $self->info( path => 'shipwright' );
        return 1 if $info;

    }

    return 0;
}

1;

__END__

=head1 NAME

Shipwright::Backend::SVN - svn backend


=head1 DESCRIPTION


=head1 DEPENDENCIES


None.


=head1 INCOMPATIBILITIES

None reported.


=head1 BUGS AND LIMITATIONS

No bugs have been reported.

=head1 AUTHOR

sunnavy  C<< <sunnavy@bestpractical.com> >>


=head1 LICENCE AND COPYRIGHT

Copyright 2007 Best Practical Solutions.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

