package Pinto::Role::PackageImporter;

# ABSTRACT: Something that imports packages from another repository

use Moose::Role;

use Try::Tiny;

use Pinto::PackageExtractor;
use Pinto::Exceptions qw(throw_error);
use Pinto::Util;

use namespace::autoclean;

#------------------------------------------------------------------------------

# VERSION

#------------------------------------------------------------------------------
# Attributes

has extractor => (
    is         => 'ro',
    isa        => 'Pinto::PackageExtractor',
    lazy_build => 1,
);

#------------------------------------------------------------------------------
# Roles

with qw( Pinto::Interface::Loggable );

#------------------------------------------------------------------------------
# Required interface

requires qw( repos stack );

#------------------------------------------------------------------------------
# Builders

sub _build_extractor {
    my ($self) = @_;

    return Pinto::PackageExtractor->new( config => $self->config(),
                                         logger => $self->logger() );
}

#------------------------------------------------------------------------------

sub find_or_import {
    my ($self, $pkg_spec) = @_;

    my ($pkg_name, $pkg_ver) = ($pkg_spec->{name}, $pkg_spec->{version});
    my $pkg_vname = "$pkg_name-$pkg_ver";

    $self->note("Looking for package $pkg_vname");
    my $latest = $self->repos->get_latest_package(name => $pkg_name);


    if ($latest && $latest->version() >= $pkg_ver) {
        my $dist = $latest->distribution();
        $self->note("Already have package $pkg_vname or newer as $latest");
        $self->repos->register_distribution(dist => $dist, stack => $self->stack);
        return ($dist, 0);
    }

    my $dist_url = $self->repos->cache->locate( package => $pkg_name,
                                                version => $pkg_ver,
                                                latest  => 1 );


    throw_error "Cannot find $pkg_vname anywhere"
        if not $dist_url;


    $self->debug("Found package $pkg_vname or newer in $dist_url");

    if ( Pinto::Util::isa_perl($dist_url) ) {
        $self->debug("Distribution $dist_url is a perl.  Skipping it.");
        return;
    }

    my $dist = $self->repos->import_distribution( url   => $dist_url,
                                                  stack => $self->stack() );

    return ($dist, 1);
}


#------------------------------------------------------------------------------

sub import_prerequisites {
    my ($self, $archive, $stack) = @_;

    my @prereq_queue = $self->_extract_prerequisites($archive);
    my %visited = ($archive => 1);
    my @imported;
    my %seen;

  PREREQ:
    while (my $prereq = shift @prereq_queue) {

        my ($required_dist, $imported_flag) = try {
              $self->find_or_import( $prereq, $stack );
        }
        catch {
             my $prereq_vname = "$prereq->{name}-$prereq->{version}";
             $self->whine("Skipping prerequisite $prereq_vname. $_");
             # Mark the prereq as done so we don't try to import it again
             $seen{ $prereq->{name} } = $prereq;
             undef;  # returned by try{}
        };

        next PREREQ if not $required_dist;
        my $required_archive = $required_dist->archive( $self->config->root_dir() );
        push @imported, $required_dist if $imported_flag;

        if ( $visited{$required_archive} ) {
            # We don't need to extract prereqs from the same dist more than once
            $self->debug("Already visited archive $required_archive");
            next PREREQ;
        }

      NEW_PREREQ:
        for my $new_prereq ( $self->_extract_prerequisites($required_archive) ) {

            # This is all pretty hacky.  It might be better to represent the queue
            # as a hash table instead of a list, since we really need to keep track
            # of things by name.

            # Add this prereq to the queue only if greater than the ones we already got
            my $name = $new_prereq->{name};

            next NEW_PREREQ if exists $seen{$name}
                               && $new_prereq->{version} <= $seen{$name};


            # Take any prior versions of this prereq out of the queue
            @prereq_queue = grep { $_->{name} ne $name } @prereq_queue;

            # Note that this is the latest version of this prereq we've seen so far
            $seen{$name} = $new_prereq->{version};

            # Push the prereq onto the queue
            push @prereq_queue, $new_prereq;
        }

        $visited{$required_archive} = 1;
    }

    return @imported;
}

#------------------------------------------------------------------------------

sub _extract_prerequisites {
    my ($self, $archive) = @_;

    # If extraction fails, then just warn and return an empty list.  The
    # caller should just go on to the next archive.  The user will have
    # to figure out the prerequisites by other means.

    my @prereqs = try   { $self->extractor->requires( archive => $archive ) }
                  catch { $self->whine("Unable to extract prerequisites from $archive: $_"); () };

    return @prereqs;
}

#------------------------------------------------------------------------------


1;

__END__
