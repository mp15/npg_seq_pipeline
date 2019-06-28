use strict;
use warnings;
use Test::More tests => 8;
use Test::Exception;
use File::Temp qw(tempdir);
use Graph::Directed;
use Log::Log4perl qw(:levels);
use Perl6::Slurp;
use JSON qw(from_json);

use_ok('npg_pipeline::product');
use_ok('npg_pipeline::function::definition');
use_ok('npg_pipeline::executor::wr');

my $tmp = tempdir(CLEANUP => 1);

Log::Log4perl->easy_init({layout => '%d %-5p %c - %m%n',
                          level  => $DEBUG,
                          file   => join(q[/], $tmp, 'logfile'),
                          utf8   => 1});

subtest 'object creation' => sub {
  plan tests => 1;

  my $e = npg_pipeline::executor::wr->new(
    function_definitions => {},
    function_graph       => Graph::Directed->new());
  isa_ok ($e, 'npg_pipeline::executor::wr');
};

subtest 'wr conf file' => sub {
  plan tests => 5;
  my $e = npg_pipeline::executor::wr->new(
    function_definitions => {},
    function_graph       => Graph::Directed->new());
  my $conf = $e->wr_conf;
  is (ref $conf, 'HASH', 'configuration is a hash ref');
  while (my ($key, $value) = each %{$conf}) {
    if ( $key =~ /queue\Z/ ) {
      is_deeply ($value,
      $key =~ /\Ap4stage1/ ? {'cloud_flavor' => 'ukb1.2xlarge'} : {},
      "correct settings for $key");
    }
  }
};

subtest 'wr add command' => sub {
  plan tests => 6;

  my $get_env = sub {
    my @env = ();
    for my $name (sort qw/PATH PERL5LIB IRODS_ENVIRONMENT_FILE
                          CLASSPATH NPG_CACHED_SAMPLESHEET_FILE
                          NPG_REPOSITORY_ROOT/) {
      my $v = $ENV{$name};
      if ($v) {
        push @env, join(q[=], $name, $v);
      }
    }
    my $env_string = join q[,], @env;
    return q['] . $env_string . q['];
  }; 
 
  local $ENV{NPG_CACHED_SAMPLESHEET_FILE} = q[];
  my $env_string = $get_env->();
  unlike  ($env_string, qr/NPG_CACHED_SAMPLESHEET_FILE/,
    'env does not contain samplesheet');
  my $file = "$tmp/commands.txt";
  my $e = npg_pipeline::executor::wr->new(
    function_definitions    => {},
    function_graph          => Graph::Directed->new(),
    commands4jobs_file_path => $file);
  is ($e->_wr_add_command(),
    "wr add --cwd /tmp --disk 0 --override 2 --retries 1 --env $env_string -f $file",
    'wr command');

  local $ENV{NPG_CACHED_SAMPLESHEET_FILE} = 't/data/samplesheet_1234.csv';
  $env_string = $get_env->();
  like  ($env_string, qr/NPG_CACHED_SAMPLESHEET_FILE/,
    'env contains samplesheet');
  is ($e->_wr_add_command(),
    "wr add --cwd /tmp --disk 0 --override 2 --retries 1 --env $env_string -f $file",
    'wr command');
  local $ENV{NPG_REPOSITORY_ROOT} = 't/data';
  $env_string = $get_env->();
  like  ($env_string, qr/NPG_REPOSITORY_ROOT/, 'env contains ref repository');
  is ($e->_wr_add_command(),
    "wr add --cwd /tmp --disk 0 --override 2 --retries 1 --env $env_string -f $file",
    'wr command');
};

subtest 'definition for a job' => sub {
  plan tests => 2;

  my $ref = {
    created_by    => __PACKAGE__,
    created_on    => 'today',
    identifier    => 1234,
    job_name      => 'job_name',
    command       => '/bin/true',
    num_cpus      => [1],
    queue         => 'small'
  };
  my $fd = npg_pipeline::function::definition->new($ref);

  my $g = Graph::Directed->new();
  $g->add_edge('pipeline_wait4path', 'pipeline_start');
  my $e = npg_pipeline::executor::wr->new(
    function_definitions => {
      'pipeline_wait4path' => [$fd], 'pipeline_start' => [$fd]},
    function_graph       => $g
  );

  my $job_def = $e->_definition4job('pipeline_wait4path', 'some_dir', $fd);
  my $expected = { 'cmd' => '(umask 0002 && /bin/true ) 2>&1',
                   'cpus' => 1,
                   'priority' => 0,
                   'memory' => '2000M' };
  is_deeply ($job_def, $expected, 'job definition without tee-ing to a log file');

  $ref->{'num_cpus'} = [0];
  $ref->{'memory'}   = 100;
  $fd = npg_pipeline::function::definition->new($ref);
  $expected = {
    'cmd' => '(umask 0002 && /bin/true ) 2>&1 | tee -a "some_dir/pipeline_start-today-1234.out"',
    'cpus' => 0,
    'priority' => 0,
    'memory'   => '100M' };
  $job_def = $e->_definition4job('pipeline_start', 'some_dir', $fd);
  is_deeply ($job_def, $expected, 'job definition with tee-ing to a log file');
};

subtest 'dependencies' => sub {
  plan tests => 45;

  my $g = Graph::Directed->new();
  $g->add_edge('pipeline_start', 'function1');
  $g->add_edge('pipeline_start', 'function2');
  $g->add_edge('function1', 'function3');
  $g->add_edge('function2', 'function3');
  $g->add_edge('function3', 'function4');
  $g->add_edge('function4', 'pipeline_end');

  my $ref = {
    created_by    => 'test',
    created_on    => 'today',
    identifier    => 'my_id',
    job_name      => 'job_name',
    command       => '/bin/true',
  };
  my $fd = npg_pipeline::function::definition->new($ref);
  
  my $definitions = {'pipeline_start' => [$fd], 'pipeline_end' => [$fd]};

  $definitions->{'function1'} = [
    npg_pipeline::function::definition->new(%{$ref},
      composition => npg_pipeline::product->new(rpt_list => '2345:1')->composition)
                                 ];

  $definitions->{'function2'} = [
    npg_pipeline::function::definition->new(%{$ref},
      composition => npg_pipeline::product->new(rpt_list => '2345:1:1')->composition),
    npg_pipeline::function::definition->new(%{$ref},
      composition => npg_pipeline::product->new(rpt_list => '2345:1:2')->composition)
                                 ];

  $definitions->{'function3'} =  $definitions->{'function2'};

  $definitions->{'function4'} =  [(
    @{$definitions->{'function3'}},
    npg_pipeline::function::definition->new(%{$ref},
      composition => npg_pipeline::product->new(rpt_list => '2345:1:3')->composition)
                                  )];

  my $file = "$tmp/wr_input.json";
  my $e = npg_pipeline::executor::wr->new(
    function_definitions => $definitions,
    function_graph       => $g,
    interactive          => 1,
    commands4jobs_file_path => $file
  );
  
  lives_ok { $e->execute() } 'runs OK';
  my @lines = slurp $file;
    #########################
    # Example of output file
    # {"cmd":"(umask 0002 && /bin/true ) 2>&1 | tee -a \"/tmp/jqmtVG38qF/log/pipeline_start/pipeline_start-today-my_id.out\"","dep_grps":["pipeline_start-my_id-3987079762","pipeline_start-my_id-3987079762-0"],"memory":"2000M","priority":0,"rep_grp":"my_id-pipeline_start"}
    # {"cmd":"(umask 0002 && /bin/true ) 2>&1 | tee -a \"/tmp/jqmtVG38qF/log/function2/function2-today-2345:1:1.out\"","dep_grps":["function2-my_id-2434227795","function2-my_id-2434227795-0"],"deps":["pipeline_start-my_id-3987079762"],"memory":"2000M","priority":0,"rep_grp":"my_id-function2"}
    # {"cmd":"(umask 0002 && /bin/true ) 2>&1 | tee -a \"/tmp/jqmtVG38qF/log/function2/function2-today-2345:1:2.out\"","dep_grps":["function2-my_id-2434227795","function2-my_id-2434227795-1"],"deps":["pipeline_start-my_id-3987079762"],"memory":"2000M","priority":0,"rep_grp":"my_id-function2"}
    # {"cmd":"(umask 0002 && /bin/true ) 2>&1 | tee -a \"/tmp/jqmtVG38qF/log/function1/function1-today-2345:1.out\"","dep_grps":["function1-my_id-1848022402","function1-my_id-1848022402-0"],"deps":["pipeline_start-my_id-3987079762"],"memory":"2000M","priority":0,"rep_grp":"my_id-function1"}
    # {"cmd":"(umask 0002 && /bin/true ) 2>&1 | tee -a \"/tmp/jqmtVG38qF/log/function3/function3-today-2345:1:1.out\"","dep_grps":["function3-my_id-113545543","function3-my_id-113545543-0"],"deps":["function1-my_id-1848022402","function2-my_id-2434227795-0"],"memory":"2000M","priority":0,"rep_grp":"my_id-function3"}
    # {"cmd":"(umask 0002 && /bin/true ) 2>&1 | tee -a \"/tmp/jqmtVG38qF/log/function3/function3-today-2345:1:2.out\"","dep_grps":["function3-my_id-113545543","function3-my_id-113545543-1"],"deps":["function1-my_id-1848022402","function2-my_id-2434227795-1"],"memory":"2000M","priority":0,"rep_grp":"my_id-function3"}
    # {"cmd":"(umask 0002 && /bin/true ) 2>&1 | tee -a \"/tmp/jqmtVG38qF/log/function4/function4-today-2345:1:1.out\"","dep_grps":["function4-my_id-2369338210","function4-my_id-2369338210-0"],"deps":["function3-my_id-113545543-0"],"memory":"2000M","priority":0,"rep_grp":"my_id-function4"}
    # {"cmd":"(umask 0002 && /bin/true ) 2>&1 | tee -a \"/tmp/jqmtVG38qF/log/function4/function4-today-2345:1:2.out\"","dep_grps":["function4-my_id-2369338210","function4-my_id-2369338210-1"],"deps":["function3-my_id-113545543-1"],"memory":"2000M","priority":0,"rep_grp":"my_id-function4"}
    # {"cmd":"(umask 0002 && /bin/true ) 2>&1 | tee -a \"/tmp/jqmtVG38qF/log/function4/function4-today-2345:1:3.out\"","dep_grps":["function4-my_id-2369338210","function4-my_id-2369338210-2"],"deps":["function3-my_id-113545543"],"memory":"2000M","priority":0,"rep_grp":"my_id-function4"}
    # {"cmd":"(umask 0002 && /bin/true ) 2>&1 | tee -a \"/tmp/jqmtVG38qF/log/pipeline_end/pipeline_end-today-my_id.out\"","dep_grps":["pipeline_end-my_id-3260187172","pipeline_end-my_id-3260187172-0"],"deps":["function4-my_id-2369338210"],"memory":"2000M","priority":0,"rep_grp":"my_id-pipeline_end"}
    #########################

  my $h = from_json pop @lines; # pipeline_end
  ok ($h->{"dep_grps"} && $h->{"deps"}, 'dependencies keys present');
  is (scalar @{$h->{"dep_grps"}}, 2, 'two groups are defined for the job');
  like ($h->{"dep_grps"}->[0], qr/\Apipeline_end-my_id-\d+\Z/, 'generic group');
  is ($h->{"dep_grps"}->[1], $h->{"dep_grps"}->[0] . '-0', 'specific group');
  is (scalar @{$h->{"deps"}}, 1, 'depends on one job');
  like ($h->{"deps"}->[0], qr/\Afunction4-my_id-\d+\Z/, 'dependency is generic');

  for my $id (qw/2 1 0/) {
    $h = from_json pop @lines;
    ok ($h->{"dep_grps"} && $h->{"deps"}, 'dependencies keys present');
    is (scalar @{$h->{"dep_grps"}}, 2, 'two groups are defined for the job');
    like ($h->{"dep_grps"}->[0], qr/\Afunction4-my_id-\d+\Z/, 'generic group');
    is ($h->{"dep_grps"}->[1], join(q[-],$h->{"dep_grps"}->[0],$id), 'specific group');
    is (scalar @{$h->{"deps"}}, 1, 'depends on one job');
    if ($id eq '2') {
      like ($h->{"deps"}->[0], qr/\Afunction3-my_id-\d+\Z/, 'dependency is generic');
    } else {
      like ($h->{"deps"}->[0], qr/\Afunction3-my_id-\d+-$id\Z/, 'dependency is specific');
    }
  }

  for my $id (qw/1 0/) {
    $h = from_json pop @lines;
    ok ($h->{"dep_grps"} && $h->{"deps"}, 'dependencies keys present');
    is (scalar @{$h->{"dep_grps"}}, 2, 'two groups are defined for the job');
    like ($h->{"dep_grps"}->[0], qr/\Afunction3-my_id-\d+\Z/, 'generic group');
    is ($h->{"dep_grps"}->[1], join(q[-],$h->{"dep_grps"}->[0],$id), 'specific group');
    is (scalar @{$h->{"deps"}}, 2, 'depends on two jobs');
    my $i = 0;
    my $j = 1;
    if ($h->{"deps"}->[0] =~ /function2/) {
      $i = 1;
      $j = 0;
    } 
    like ($h->{"deps"}->[$i], qr/\Afunction1-my_id-\d+\Z/, 'dependency is generic');
    like ($h->{"deps"}->[$j], qr/\Afunction2-my_id-\d+-$id\Z/, 'dependency is specific');
  }

  is (scalar @lines, 4, 'four jobs remain');
  $h = from_json shift @lines;
  ok ($h->{"dep_grps"}, 'dependency groups are defined');
  ok (!exists $h->{"deps"}, 'the job does not depend on any other job');
  is (scalar @{$h->{"dep_grps"}}, 2, 'two groups are defined for the job');
  like ($h->{"dep_grps"}->[0], qr/\Apipeline_start-my_id-\d+\Z/, 'generic group');
  is ($h->{"dep_grps"}->[1], join(q[-],$h->{"dep_grps"}->[0],0), 'specific group')
};

1;
