package npg_pipeline::function::bqsr_calc;

use namespace::autoclean;

use Moose;
use MooseX::StrictConstructor;
use Readonly;

use npg_pipeline::cache::reference;
use npg_pipeline::function::definition;

extends 'npg_pipeline::base';
with qw{ npg_pipeline::function::util
         npg_pipeline::product::release };
with 'npg_common::roles::software_location' => { tools => [qw/gatk/] };

Readonly::Scalar my $FUNCTION_NAME => 'bqsr_calc';

Readonly::Scalar my $GATK_TOOL_NAME => 'BaseRecalibrator';

Readonly::Scalar my $FS_NUM_SLOTS                 => 2;
Readonly::Scalar my $MEMORY                       => q{2000}; # memory in megabytes
Readonly::Scalar my $CPUS                         => 1;
Readonly::Scalar my $NUM_HOSTS                    => 1;


our $VERSION = '0';

=head2 create

  Arg [1]    : None

  Example    : my $defs = $obj->create
  Description: Create per-product data file function definitions.

  Returntype : ArrayRef[npg_pipeline::function::definition]

=cut

sub create {
  my ($self) = @_;

  my $label = $self->label();
  my $job_name = sprintf q{%s_%d}, $FUNCTION_NAME, $label;

  # If BQSR is disabled we should not run.
  my @products = grep { $self->bqsr_enable($_) }
                 grep { $self->is_release_data($_) }
                 @{$self->products->{data_products}};

  if (scalar @products == 0) {
    $self->debug('no BQSR enabled data products, skipping');
  }
  my @definitions = ();


  foreach my $product (@products) {
    my $dir_path = $product->path($self->archive_path());

    my $input_path = $product->file_path($dir_path, ext => 'cram');
    my $output_path = $product->file_path($dir_path, ext => 'bqsr_table');
    my $ref_path = npg_pipeline::cache::reference->instance->get_path($product, q(fasta), $self->repository());

    my ($species, $ref, undef, undef) = npg_tracking::data::reference::find->parse_reference_genome($product->lims->reference_genome());
    my @known_sites_str = map { sprintf '--known-sites %s/resources/%s/%s/%s.vcf.gz',
        $self->repository,
        $species,
        $ref,
        $_;
      }
      $self->bqsr_known_sites($product);

    my $known_sites_opt = join q{ }, @known_sites_str;

    #    my $bqsr_opts = '';
    my $command = sprintf q{%s %s -O %s -I %s -R %s %s},
      $self->gatk_cmd, $GATK_TOOL_NAME, $output_path, $input_path, $ref_path, $known_sites_opt;

    $self->debug("Adding command '$command'");

    push @definitions,
      npg_pipeline::function::definition->new
        ('created_by'   => __PACKAGE__,
         'created_on'   => $self->timestamp(),
         'identifier'   => $label,
         'job_name'     => $job_name,
         'command'      => $command,
         'fs_slots_num' => $FS_NUM_SLOTS,
         'num_hosts'    => $NUM_HOSTS,
         'num_cpus'     => [$CPUS],
         'memory'       => $MEMORY,
         'composition'  => $product->composition());
  }

  if (not @definitions) {
    push @definitions, npg_pipeline::function::definition->new
      ('created_by' => __PACKAGE__,
       'created_on' => $self->timestamp(),
       'identifier' => $label,
       'excluded'   => 1);
  }

  return \@definitions;
}

__PACKAGE__->meta->make_immutable;

1;

__END__

=head1 NAME

npg_pipeline::function::bqsr_calc

=head1 SYNOPSIS

  my $obj = npg_pipeline::function::bqsr_calc->new
    (runfolder_path => $runfolder_path);

=head1 DESCRIPTION


=head1 SUBROUTINES/METHODS

=head1 BUGS AND LIMITATIONS

=head1 INCOMPATIBILITIES

=head1 DIAGNOSTICS

=head1 CONFIGURATION AND ENVIRONMENT

=head1 DEPENDENCIES

=over

=item namespace::autoclean

=item Moose
 
=item MooseX::StrictConstructor

=item Readonly

=item npg_tracking::data::reference::find

=item npg_common::roles::software_location

=back

=head1 AUTHOR

Martin Pollard

=head1 LICENSE AND COPYRIGHT

Copyright (C) 2019 Genome Research Ltd.

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
