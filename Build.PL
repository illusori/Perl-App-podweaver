use strict;
use warnings;
use Module::Build;

my $builder = Module::Build->new(
    module_name         => 'App::podweaver',
    license             => 'perl',
    dist_author         => q{Sam Graham <libapp-podweaver-perl@illusori.co.uk>},
    dist_version_from   => 'lib/App/podweaver.pm',
    script_files        => 'script',
    build_requires => {
        'Test::More' => 0,
    },
    add_to_cleanup      => [ 'App-podweaver-*' ],
    sign => 1,
    dynamic_config => 0,
);

$builder->create_build_script();
