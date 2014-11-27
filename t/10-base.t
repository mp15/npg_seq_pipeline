use strict;
use warnings;
use Test::More tests => 42;
use Test::Exception;
use t::util;
use File::Temp qw(tempdir tempfile);
use Cwd;
use Sys::Filesystem::MountPoint qw(path_to_mount_point);
use Sys::Hostname;

use_ok(q{npg_pipeline::base});

{
  throws_ok {npg_pipeline::base->new(no_bsub => 3)} qr/Validation failed for 'Bool' (failed[ ])?with value 3/, 'error trying to set boolean flag to 3';
  my $base = npg_pipeline::base->new();
  isa_ok($base, q{npg_pipeline::base});
  is($base->no_bsub, undef, 'no_bsub flag value is undefined if not set');
  ok(!$base->no_bsub, '   ... and it evaluates to false');
  is($base->local, 0, 'local flag is 0');
  $base = npg_pipeline::base->new(no_bsub => q[]);
  is($base->no_bsub, q[], 'no_bsub flag value is empty string as set');
  ok(!$base->no_bsub, '   ... and it evaluates to false');
  $base = npg_pipeline::base->new(no_bsub => 0);
  is($base->no_bsub, 0, 'no_bsub flag value is 0 as set');
  ok(!$base->no_bsub, '   ... and it evaluates to false');
  is($base->local, 0, 'local flag is 0');
  $base = npg_pipeline::base->new(no_bsub => 1);
  is($base->no_bsub, 1, 'no_bsub flag value is 1 as set');
  ok($base->no_bsub, '   ... and it evaluates to true');
  is($base->local, 1, 'local flag is 1');
  $base = npg_pipeline::base->new(local => 1);
  is($base->local, 1, 'local flag is 1 as set');
  $base = npg_pipeline::base->new(no_bsub => 0, local => 1);
  is($base->local, 1, 'local flag is 1 as set');
  is($base->no_bsub, 0, 'no_sub flag is 0 as set');
}

{
  my $base = npg_pipeline::base->new();
  ok(!$base->olb, 'OLB preprocessing is switched off by default');
  $base = npg_pipeline::base->new(olb => 1);
  ok($base->olb, 'OLB preprocessing is switched on as set');
}

{
  my $base;
  lives_ok {
    $base = npg_pipeline::base->new({
      conf_path => q{data/config_files},
      domain => q{test},
    });
  } q{base ok};

  foreach my $config_group ( qw{
    external_script_names_conf
    function_order_conf
    general_values_conf
    illumina_pipeline_conf
    pb_cal_pipeline_conf
  } ) {
    isa_ok( $base->$config_group(), q{HASH}, q{$} . qq{base->$config_group} );
  }
}

{
  my $base;
  lives_ok {
    $base = npg_pipeline::base->new({
      conf_path => q{does/not/exist},
      domain => q{test},
    });
  } q{base ok};

  throws_ok{ $base->general_values_conf()} qr{cannot find }, 'Croaks for non-esistent config file as expected';;
}

{
  local $ENV{TEST_FS_RESOURCE} = q{nfs_12};
  my $expected_fs_resource =  q{nfs_12};
  my $path = t::util->new()->temp_directory;
  my $base = npg_pipeline::base->new( id_run => 7440, runfolder_path => $path);
  my $arg = q{-R 'select[mem>2500] rusage[mem=2500]' -M2500000};
  is ($base->fs_resource_string({resource_string => $arg,}), qq[-R 'select[mem>2500] rusage[mem=2500,$expected_fs_resource=8]' -M2500000], 'resource string with sf resource');
  is ($base->fs_resource_string({resource_string => $arg, seq_irods => 1,}), qq[-R 'select[mem>2500] rusage[mem=2500,$expected_fs_resource=8,seq_irods=1]' -M2500000], 'resource string with sf and irods resource');
  $base = npg_pipeline::base->new(id_run => 7440, runfolder_path => $path , no_sf_resource => 1);
  is ($base->fs_resource_string({resource_string => $arg,}), $arg, 'resource string with no sr resource if no_sf_resource is set');

  $arg = q{-R 'select[mem>13800] rusage[mem=13800] span[hosts=1]'};
  is ($base->fs_resource_string({resource_string => $arg, counter_slots_per_job => 8,}), $arg, 'resource string with no sr resource if no_sf_resource is set');
}

{
  my $host = hostname;
  SKIP: {
    skip 'Not running on a farm node', 1 unless ($host =~ /^sf/);
    my $basedir = tempdir( CLEANUP => 1 );
    my $base = npg_pipeline::base->new(id_run => 1234, runfolder_path => $basedir);
    is($base->_fs_resource, 'tmp', 'fs_resourse as expected');
  }
}

{
  local $ENV{NPG_WEBSERVICE_CACHE_DIR} = q[t/data/hiseqx];
  my $base = npg_pipeline::base->new(id_run => 13219);
  ok($base->is_hiseqx_run, 'is a HiSeqX instrument run');
  local $ENV{NPG_WEBSERVICE_CACHE_DIR} = q[t/data];
  $base = npg_pipeline::base->new(id_run => 1234);
  ok(!$base->is_hiseqx_run, 'is not a HiSeqX instrument run');
}

{
  my $dir = tempdir( CLEANUP => 1 );
  my ($fh, $file) = tempfile( 'tmpfileXXXX', DIR => $dir);
  
  local $ENV{NPG_WEBSERVICE_CACHE_DIR} = $dir;
  local $ENV{NPG_CACHED_SAMPLESHEET_FILE} = q[];
  is (npg_pipeline::base->metadata_cache_dir(), $dir, 'cache dir from webservice cache dir');
  local $ENV{NPG_CACHED_SAMPLESHEET_FILE} = $file;
  is (npg_pipeline::base->metadata_cache_dir(), $dir, 'cache dir from two consistent caches');
  local $ENV{NPG_WEBSERVICE_CACHE_DIR} = q[];
  is (npg_pipeline::base->metadata_cache_dir(), $dir, 'cache dir from samplesheet path');
  local $ENV{NPG_WEBSERVICE_CACHE_DIR} = q[t];
  throws_ok {npg_pipeline::base->metadata_cache_dir()}
    qr/Multiple possible locations for metadata cache directory/,
    'inconsistent locations give an error';
  local $ENV{NPG_WEBSERVICE_CACHE_DIR} = q[some];
  is (npg_pipeline::base->metadata_cache_dir(), $dir, 'one valid and one invalid path is OK');
  local $ENV{NPG_CACHED_SAMPLESHEET_FILE} = q[other];
  throws_ok {npg_pipeline::base->metadata_cache_dir()}
    qr/Cannot infer location of cache directory/,
    'error with two invalid paths';
  local $ENV{NPG_CACHED_SAMPLESHEET_FILE} = q[];
  throws_ok {npg_pipeline::base->metadata_cache_dir()}
    qr/Cannot infer location of cache directory/,
    'error with one path that is invalid';
  local $ENV{NPG_WEBSERVICE_CACHE_DIR} = q[];
  throws_ok {npg_pipeline::base->metadata_cache_dir()}
    qr/Cannot infer location of cache directory/,
    'error when no env vars are set';
}

1;
