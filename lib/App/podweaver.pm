package App::podweaver;

# ABSTRACT: Run Pod::Weaver on the files within a distribution.

use warnings;
use strict;

use Carp;
use File::Slurp ();
use Log::Any qw/$log/;
use Try::Tiny;

our $VERSION = '0.99_01';

sub FAIL()              { 0; }
sub SUCCESS_UNCHANGED() { 1; }
sub SUCCESS_CHANGED()   { 1; }

sub weave_file
{
    my ( $self, %input ) = @_;
    my ( $file, $no_backup, $write_to_dot_new );
    my ( $perl, $ppi_document, $pod_after_end, @pod_tokens, $pod_str,
         $pod_document, %weave_args, $new_pod, $end, $new_perl,
         $output_file, $backup_file, $fh );

    unless( $file = delete $input{ file } )
    {
        $log->errorf( 'Missing file parameter in args %s', \%input )
            if $log->is_error();
        return( FAIL );
    }
    $no_backup        = delete $input{ no_backup };
    $write_to_dot_new = delete $input{ new }

    #  From here and below is mostly hacked out from
    #    Dist::Zilla::Plugin::PodWeaver

    $perl = File::Slurp::read_file( $file );

    unless( $ppi_document = PPI::Document->new( \$perl ) )
    {
        $log->errorf( "PPI error in '%s': %s", $file, PPI::Document->errstr() )
            if $log->is_error();
        return( FAIL );
    }

    #  Pod::Weaver::Section::Name croaks if there's no package line.
    unless( $ppi_document->find_first( 'PPI::Statement::Package' ) )
    {
        $log->errorf( "Unable to find package declaration in '%s'", $file )
            if $log->is_error();
        return( FAIL );
    }

    #  If they have some pod after __END__ then assume it's safe to put
    #  it all there.
    $pod_after_end =
        ( $ppi_document->find( 'PPI::Statement::End' ) and
          grep { $_->find_first( 'PPI::Token::Pod' ) }
              @{$ppi_document->find( 'PPI::Statement::End' )} ) ?
        1 : 0;

    @pod_tokens =
        map { "$_" } @{ $ppi_document->find( 'PPI::Token::Pod' ) || [] };
    $ppi_document->prune( 'PPI::Token::Pod' );

    if( $ppi_document->serialize =~ /^=[a-z]/m )
    {
        #  TODO: no idea what the problem is here, but DZP::PodWeaver had it...
        $log->errorf( "Can't do podweave on '%s': " .
            "there is POD inside string literals", $file )
            if $log->is_error();
        return( FAIL );
    }

    $pod_str = join "\n", @pod_tokens;
    $pod_document = Pod::Elemental->read_string( $pod_str );

#  TODO: This _really_ doesn't like being run twice on a document with
#  TODO: regions for some reason.  Comment out for now and trust they
#  TODO: have [@CorePrep] enabled.
#    Pod::Elemental::Transformer::Pod5->new->transform_node( $pod_document );

    %weave_args = (
        %input,
        pod_document => $pod_document,
        ppi_document => $ppi_document,
        filename     => $file,
        );
    #  FIXME: erk, not right at all if the module version differs...
    $weave_args{ version } = $dist_version if $dist_version;

    #  TODO: Try::Tiny this, it can croak.
    try
    {
        $pod_document = $weaver->weave_document( \%weave_args );

        $log->errorf( "weave_document() failed on '%s': No Pod generated",
            $file )
            if $log->is_error() and not $pod_document;
    }
    catch
    {
        $log->errorf( "weave_document() failed on '%s': %s",
            $file, $_ )
            if $log->is_error();
        $pod_document = undef;
    };
    return( FAIL ) unless $pod_document;

    $new_pod = $pod_document->as_pod_string;

    $end = do {
        my $end_elem = $ppi_document->find( 'PPI::Statement::Data' )
                    || $ppi_document->find( 'PPI::Statement::End' );
        join q{}, @{ $end_elem || [] };
        };

    $ppi_document->prune( 'PPI::Statement::End' );
    $ppi_document->prune( 'PPI::Statement::Data' );

    $new_perl = $ppi_document->serialize;
    $new_perl =
        $end ? ( $pod_after_end ?
        "$new_perl$end$new_pod" :
        "$new_perl\n\n$new_pod\n\n$end" ) :
        "$new_perl\n__END__\n$new_pod\n";

    if( $perl eq $new_perl )
    {
        $log->infof( "Contents of '%s' unchanged", $file )
            if $log->is_info();
        return( SUCCESS_UNCHANGED );
    }

    $output_file = $write_to_dot_new ? ( $file . '.new' ) : $file;
    $backup_file = $file . '.bak';

    unless( $write_to_dot_new or $no_backup )
    {
        unlink( $backup_file );
        copy( $file, $backup_file );
    }

    $log->debugf( "Writing new '%s' for '%s'", $output_file, $file )
        if $log->is_debug();
    #  We want to preserve permissions and other stuff, so we open
    #  it for read/write.
    $fh = IO::File->new( $output_file, $write_to_dot_new ? '>' : '+<' );
    unless( $fh )
    {
        $log->errorf( "Unable to write to '%s' for '%s': %s"
            $output_file, $file, $! )
            if $log->is_error();
        return( FAIL );
    }
    $fh->truncate( 0 );
    $fh->print( $new_perl );
    $fh->close();
    return( SUCCESS_CHANGED );
}

1;

__END__

=pod

=head1 NAME

App::podweaver - Run Pod::Weaver on the files within a distribution.

=head1 VERSION

version 0.99_01

=head1 SYNOPSIS

L<App::podweaver> provides a mechanism to run L<Pod::Weaver> over the files
within a distribution, without needing to use L<Dist::Zilla>.

Where L<Dist::Zilla> works on a copy of your source code, L<App::podweaver>
is intended to modify your source code directly, and as such it is highly
recommended that you use the L<Pod::Weaver::PluginBundle::ReplaceBoilerplate>
plugin bundle so that you over-write existing POD sections, instead of the
default L<Pod::Weaver> behaviour of repeatedly appending.

You can configure the L<Pod::Weaver> invocation by providinng a
C<weaver.ini> file in the root directory of your distribution.

=head1 BOOTSTRAPPING WITH META.json/META.yml

Since the META.json/yml file is often generated with an abstract extracted
from the POD, and L<App::podweaver> expects a valid META file for
some of the information to insert into the POD, there's a chicken-and-egg
situation.

Running L<App::podweaver> first should produce a POD with an abstract
line populated from your C<< # ABSTRACT: >> header, but without additional
sections like version and authors.
You can then generate your META file as per usual, and then run
L<App::podweaver> again to produce the missing sections:

  $ ./Build distmeta
  Creating META.yml
  ERROR: Missing required field 'dist_abstract' for metafile
  $ podweaver -v
  No META.json or META.yml file found, are you running in a distribution directory?
  Processing lib/App/podweaver.pm
  $ ./Build distmeta
  Creating META.yml
  $ podweaver -v
  Processing lib/App/podweaver.pm

This should only be neccessary on newly created distributions as
both the META and the neccessary POD abstract should be present
subsequently.

=head1 KNOWN ISSUES AND BUGS

=over

=item Currently skips files without C<package> declaration.

L<Pod::Weaver::Plugin::Name> croaks if there's no C<package> declaration
in the file, preventing L<Pod::Weaver> from running over scripts and
C<.pod> files at this time.  L<App::podweaver> currently avoids trying
to run on files that will trigger this problem.

=item META.json/yml bootstrap is a mess

The whole bootstrap issue with META.json/yml is ugly.

=item Distribution version used not module $VERSION

Currently there's a quick and nasty hack supplying the distribution
version to L<Pod::Weaver::Plugin::Version> for each module, rather
than the version specified in that module.
This will be incorrect if your version numbers aren't in sync for
some reason.

=item All the code is in the script, should move into the module

All the code for "doing stuff" is in the script rather than in
this module, which makes it impossible to reuse, and rather hard
to test.
Stuff that modifies your source code B<really> ought to have some
tests.

=back

=head1 REPORTING BUGS

Please report any bugs or feature requests to C<bug-app-podweaver at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=App-podweaver>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc App::podweaver

You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=App-podweaver>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/App-podweaver>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/App-podweaver>

=item * Search CPAN

L<http://search.cpan.org/dist/App-podweaver/>

=back

=head1 AUTHOR

Sam Graham <libapp-podweaver-perl BLAHBLAH illusori.co.uk>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2010 by Sam Graham <libapp-podweaver-perl BLAHBLAH illusori.co.uk>.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut
