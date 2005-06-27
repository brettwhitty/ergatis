#!/usr/local/bin/perl

=head1	NAME

bsm2legacydb.pl - load WorkFlow BSML files into the legacy database

=head1	SYNOPSIS

USAGE: bsml2legacydb.pl
		--input_file|i=/path/to/bsml_data.bsml
		--input_list|I=/path/to/bsml_file_list
		--database|d=aa1
	[
		--debug|D=4
		--log|l=/path/to/log_file.log
	]

=head1	OPTIONS

B<--input_file,-i>
	Location of bsml input file

B<--input_list,-I>
	Location of bsml input list

B<--database,-d>
	Database where data will be loaded to

B<--debug,-D>
	Debug level.  Use a large number to turn on verbose debugging

B<--log,-l>
	Log file

B<--help,-h>
	Print help

=head1	DESCRIPTION

This script will load the WorkFlow BSML files into the legacy database

=head1	INPUT

The input is a BSML file.  It will handle BSML data from augustus, genie,
genezilla, gap2, and nap.

The name of each assembly is pulled from the BSML file names processed,
which should be of the format:

	[data_type].assembly.[assembly_id].[program_name].bsml

=head1	OUTPUT

No output file is generated unless a LOG is passed.  There are many warning
messages sent to stderr (in case of gene prediction loading) which come
from the libraries used (not generated by this code)

=head1	CONTACT

Ed Lee (elee@tigr.org)

=cut

use strict;
use warnings;
use Getopt::Long qw(:config no_ignore_case pass_through);
use Pod::Usage;
use Workflow::Logger;
use DBI;
use XML::Twig;
use IO::File;

my @files	= ();
my $server	= "SYBTIGR";
my $db		= undef;
my %opts	= ();
my %coords	= ();
my @genes	= ();
my %db_ids	= ();
my $debug	= 4;
my $log_file	= Workflow::Logger::get_default_logfilename;
my $logger	= undef;
my %id2title	= ();
my $loader	= $& if $0 =~ /[\w\.\d]+$/;

sub parse_opts;
sub print_usage;
sub process_files;
sub process_results;
sub process_feat;
sub process_feat_group;
sub process_aln;
sub process_sequence;
sub get_db_id;
sub fetch_db_id;
sub insert_db_id;
sub swap;
sub prepare_evidence_insert_stmt;
sub prepare_asm_feature_insert_stmt;
sub prepare_phys_ev_insert_stmt;
sub prepare_feat_link_insert_stmt;
sub cleanup_records;
sub get_latest_id;

GetOptions(\%opts, "input_file|i=s", "input_list|I=s",
	   "server|s=s", "database|d=s",
	   "debug|D=i", "log|l=s", "help|h");
parse_opts;

my $dbh = DBI->connect("dbi:Sybase:$server", 'egc', 'egcpwd', 
		       {RaiseError => 1, PrintError => 1}) or
	die "Error accessing db: DBI::errstr";
$dbh->do("use $db");
process_files;
$dbh->disconnect;

sub parse_opts
{
	while (my ($key, $val) = each (%opts)) {
		if ($key eq "input_file") {
			push @files, $val;
		}
		elsif ($key eq "input_list") {
			my $fh = new IO::File($val) or
				die "Error accessing input list " .
				    "$opts{input_list}: $!";
			while (my $file = <$fh>) {
				chomp $file;
				next if $file =~ /^\s*$/;
				push @files, $file;
			}
		}
		elsif ($key eq "server") {
			$server = $val;
		}
		elsif ($key eq "database") {
			$db = $val;
		}
		elsif ($key eq "debug") {
			$debug = $val;
		}
		elsif ($key eq "log") {
			$log_file = $val;
		}
		elsif ($key eq "help") {
			print_usage if $val;
		}
	}
	$logger = new Workflow::Logger('LOG_FILE' => $log_file,
				       'LOG_LEVEL' => $debug);
	$logger = Workflow::Logger::get_logger;
	$logger->logdie("No input(s) provided") if !scalar(@files);
	$logger->logdie("No database provided") if !$db;
}

sub print_usage
{
	pod2usage( {-exitval => 1, -verbose => 2, -output => \*STDERR} );
}

sub process_files
{
	foreach my $file (@files) {
		%coords = ();
		@genes = ();
		%id2title = ();
		$logger->debug("Processing $file") if $logger->is_debug;
		my $asm_id = $1 if $file =~ /\.assembly\.(\d+)/ or
			$logger->logdie("Couldn't extract assembly id from: " .
					"$file");
		my $prog_name = $1 if $file =~ /(\w+)\.bsml/ or
			$logger->logdie("Couldn't extract program name from: " .
					"$file");
		my $twig = new XML::Twig
			(twig_roots =>
				{'Feature' => \&process_feat,
				 'Feature-group' => \&process_feat_group,
				 'Seq-pair-alignment' => sub {
					my ($twig, $aln) = @_;
					process_aln($twig, $aln,
						    $asm_id, $prog_name);
					},
				 'Sequence' => \&process_sequence
				});
		$twig->parsefile($file);
		if (scalar(@genes)) {
			process_results($asm_id, $prog_name);
		}
	}
}

sub process_results
{
	my ($asm_id, $prog_name) = @_;
	$prog_name = 'GeneZilla' if $prog_name =~ /genezilla/;
	cleanup_records($asm_id, $prog_name);
	my $model_id = get_latest_id($asm_id, "model");
	my $exon_id = get_latest_id($asm_id, "exon");
	my $asm_feature_insert_stmt = prepare_asm_feature_insert_stmt;
	my $phys_ev_insert_stmt = prepare_phys_ev_insert_stmt;
	my $feat_link_insert_stmt = prepare_feat_link_insert_stmt;
	foreach my $gene_coords (@genes) {
		++$model_id;
		my $model_feat_name = "$asm_id.m$model_id";
#		print "$model_feat_name\n";
		my ($model_pos5p, $model_pos3p);
		if ($$gene_coords[0][0] < $$gene_coords[0][1]) {
			$model_pos5p = $$gene_coords[0][0];
			$model_pos3p = $$gene_coords[$#$gene_coords][1];
		}
		else {
			$model_pos5p = $$gene_coords[$#$gene_coords][0];
			$model_pos3p = $$gene_coords[0][1];
		}
#		print "[$model_pos5p\t$model_pos3p]\n";
		$asm_feature_insert_stmt->execute("model", $loader,
						  $model_pos5p, $model_pos3p,
						  $model_feat_name,
						  $asm_id);
		$phys_ev_insert_stmt->execute($model_feat_name,
					      $prog_name);
		foreach my $exon_coords (@{$gene_coords}) {
			++$exon_id;
			my $exon_feat_name = "$asm_id.e$exon_id";
			my ($exon_pos5p, $exon_pos3p) =
				($$exon_coords[0], $$exon_coords[1]);
#			print "$exon_feat_name\n";
#			print "$exon_pos5p\t$exon_pos3p\n";
			$asm_feature_insert_stmt->execute("exon", $loader,
						  $exon_pos5p, $exon_pos3p,
						  $exon_feat_name,
						  $asm_id);
			$phys_ev_insert_stmt->execute($exon_feat_name,
						      $prog_name);
			$feat_link_insert_stmt->execute($model_feat_name,
							$exon_feat_name);
		}
#		print "\n";
	}

#	my $stmt = $dbh->prepare("select feat_name, feat_type from asm_feature where asmbl_id=$asm_id");
#	$stmt->execute;
#	while ($_ = $stmt->fetchrow_arrayref) {
#		print "$$_[0]\t$$_[1]\n";
#	}
}

sub process_feat
{
	my ($twig, $feat) = @_;
	my $id = $feat->att('id') or
		$logger->logdie("Feature found with no id");
	if ($feat->att('class') eq 'exon') {
		my $seq_int = $feat->first_child('Interval-loc') or
			$logger->logdie("Feature $id has no Interval-loc");
		$logger->logdie("Feature $id missing seq positions") if
			!defined $seq_int->att('startpos') or
			!defined $seq_int->att('endpos');
		my ($start_pos, $end_pos) = ($seq_int->att('startpos') + 1,
			$seq_int->att('endpos') + 1);
		$logger->logdie("Feature $id has invalid complement value")
			if ($seq_int->att('complement') != 0 and
			$seq_int->att('complement') != 1);
		swap(\$start_pos, \$end_pos) if ($seq_int->att('complement'));
		push @{$coords{$id}}, $start_pos, $end_pos;
	}
	else {
		$logger->debug("Skipping feature $id [class is not exon]")
			if $logger->is_debug;
	}
	$twig->purge;
}

sub process_feat_group
{
	my ($twig, $feat_group) = @_;
	my @exon_coords = ();
	foreach my $child ($feat_group->children('Feature-group-member')) {
		if ($child->att('feature-type') eq 'exon') {
			my $id = $child->att('featref') or
				$logger->logdie("Feature-group-member has no " .
						"featref");
			push @exon_coords,
				[$coords{$id}->[0], $coords{$id}->[1]];
		}
	}
	if (scalar @exon_coords) {
		@exon_coords = sort { $$a[0] <=> $$b[0]; } @exon_coords;
		push @genes, \@exon_coords;
	}
	else {
		$logger->warn("Skipping feature group " .
			      $feat_group->att('group-set') .
			      " because it has no exons") if $logger->is_warn;
	}
	$twig->purge;
}

sub process_aln
{
	my ($twig, $aln, $asm_id, $prog_name) = @_;
	my $insert_stmt = prepare_evidence_insert_stmt;
	my $total_score = 0;
	foreach my $attr ($aln->children('Attribute')) {
		$total_score = $attr->att('content') and last
			if ($attr->att('name') eq 'total_score') or
			$logger->logdie("Failed to get total_score from " .
					"Seq-pair-alignment");
	}
	$logger->logdie("Cannot find compseq for Seq-pair-alignment")
		if !defined $aln->att('compseq');
	my $subj_id = $id2title{$aln->att('compseq')} or
		$logger->logdie("Cannot find id-title mapping for Sequence");
	my $db_name = $1 if $aln->att('compxref') =~ /\/([\w\.]+):/ or
		$logger->logdie("Cannot extract compxref from " .
				"Seq-pair-alignment");
	my $db_id = get_db_id($db_name);
	my $chain_num = 0;
	my $pct_id = 0;
	my $pct_sim = 0;
	foreach my $seq_pair_run ($aln->children('Seq-pair-run')) {
		my $score = $seq_pair_run->att('runscore');
		my $query_start = $seq_pair_run->att('refpos') + 1;
		my $query_aln_len = $seq_pair_run->att('runlength');
		my $query_stop = $query_start + $query_aln_len;
		my $query_comp = $seq_pair_run->att('refcomplement');
		my $subj_start = $seq_pair_run->att('comppos') + 1;
		my $subj_aln_len = $seq_pair_run->att('comprunlength');
		my $subj_stop = $subj_start + $subj_aln_len;
		my $subj_comp = $seq_pair_run->att('compcomplement');
		swap(\$query_start, \$query_stop) if $query_comp;
		swap(\$subj_start, \$subj_stop) if $subj_comp;
		foreach my $attr ($seq_pair_run->children('Attribute')) {
			if ($attr->att('name') eq 'chain_number') {
				$chain_num = $attr->att('content')
					if !$chain_num;
			}
			elsif ($attr->att('name') eq 'percent_identity') {
				$pct_id = $attr->att('content');
			}
			elsif ($attr->att('name') eq 'percent_similarity') {
				$pct_sim = $attr->att('content');
			}
		}
		$logger->logdie("Failed to extract either chain_number, " .
				"percent_identity, or percent_similarity ".
				"from Seq-pair_run")
			if !$chain_num or !$pct_id or !$pct_sim;
		my $prog_tag = $prog_name eq 'aat_aa' ? 'nap' : 'gap2';
		$insert_stmt->execute("$asm_id.intergenic", $prog_tag, 
				      $subj_id, $query_start, $query_stop,
				      $subj_start, $subj_stop, $prog_name,
				      $pct_id, $pct_sim, $score, $db_id,
				      $score, $total_score, $chain_num);
	}
	$twig->purge;
}

sub process_sequence
{
	my ($twig, $sequence) = @_;
	$id2title{$sequence->att('id')} = $sequence->att('title')
		if defined $sequence->att('id') and 
			defined $sequence->att('title');
	$twig->purge;
}

sub get_db_id
{
	my $db_name = shift;
	return $db_ids{$db_name} if exists $db_ids{$db_name};
	my $db_id = fetch_db_id($db_name);
	if (!$db_id) {
		$db_id = insert_db_id($db_name);
		$logger->debug("Got new search_dbs id $db_id for $db_name")
			if $logger->is_debug;
	}
	else {
		$logger->debug("Got existing search_dbs id $db_id for $db_name")
			if $logger->is_debug;
	}
	$logger->logdie("Failed to get search_dbs ID for database $db_name")
		if !$db_id;
	$db_ids{$db_name} = $db_id;
	return $db_id;
}

sub fetch_db_id
{
	my $db_name = shift;
	my $sql = "SELECT id FROM common..search_dbs WHERE name='$db_name'";
	my $stmt = $dbh->prepare($sql);
	$stmt->execute;
	my $rows = $stmt->fetchrow_arrayref;
	my $db_id = $rows ? $rows->[0] : 0;
	$stmt->finish;
	return $db_id;
}

sub insert_db_id
{
	my $db_name = shift;
	my $sql = "INSERT INTO common..search_dbs (name, " .
		  "release_notes, date, assignby, iscurrent, type) " .
		  "VALUES ('$db_name', NULL, getdate(), 'workflow', 1, " .
		  "'custom')";
	$dbh->do($sql);
	return fetch_db_id($db_name);
}

sub swap
{
	my ($val1, $val2) = @_;
	($$val1, $$val2) = ($$val2, $$val1);
}

sub prepare_evidence_insert_stmt
{
	my $sql = "INSERT INTO evidence (feat_name, ev_type, accession, " .
		  "end5, end3, rel_end5, rel_end3, m_lend, m_rend, curated, " .
		  "date, assignby, change_log, save_history, method, " .
		  "per_id, per_sim, score, db, pvalue, domain_score, " .
		  "expect_domain, total_score, expect_whole, chainID) " .
		  "VALUES (?, ?, ?, ?, ?, -1, -1, ?, ?, 0, getdate(), " .
		  "'workflow', 0, 0, ?, ?, ?, ?, ?, NULL, ?, NULL, ?, " .
		  "NULL, ?)";
	return $dbh->prepare($sql);
}

sub prepare_asm_feature_insert_stmt
{
	my $sql = "INSERT INTO asm_feature (feat_type, feat_method, " .
		  "end5, end3, assignby, date, feat_name, asmbl_id, " .
		  "change_log, save_history, curated) ".
		  "VALUES (?, ?, ?, ?, 'workflow', getdate(), ?, ?, 0, 0, 0)";
	return $dbh->prepare($sql);
}

sub prepare_phys_ev_insert_stmt
{
	my $sql = "INSERT INTO phys_ev (feat_name, ev_type, assignby, " .
		  "datestamp) " .
		  "VALUES (?, ?, 'workflow', getdate())";
	return $dbh->prepare($sql);
}

sub prepare_feat_link_insert_stmt
{
	my $sql = "INSERT INTO feat_link (parent_feat, child_feat, " .
		  "assignby, datestamp) " .
		  "VALUES (?, ?, 'workflow', getdate())";
	return $dbh->prepare($sql);
}

sub cleanup_records
{
	my ($asm_id, $ev_type) = @_;
	my $stmt = $dbh->prepare("SELECT p.feat_name " .
				 "FROM phys_ev p INNER JOIN asm_feature a " .
				 "ON (p.feat_name=a.feat_name) " .
				 "WHERE a.asmbl_id=$asm_id AND " .
				 "p.ev_type='$ev_type'");
	$stmt->execute;
	while (my $row = $stmt->fetchrow_arrayref) {
		$dbh->do("DELETE FROM asm_feature " .
			 "WHERE feat_name='$$row[0]'");
		$dbh->do("DELETE FROM phys_ev " .
			 "WHERE feat_name='$$row[0]'");
		$dbh->do("DELETE FROM feat_link " .
			 "WHERE parent_feat='$$row[0]' OR " .
			 "child_feat='$$row[0]'");
#		print "$$row[0]\n";
	}
}
	
sub get_latest_id
{
	my ($asm_id, $feat_type) = @_;
	my $last_array;
	my $last_feat_name =
		$dbh->selectrow_arrayref("SELECT MAX(feat_name) " .
					 "FROM asm_feature " .
					 "WHERE asmbl_id=$asm_id AND " .
					 "feat_type='$feat_type'")->[0];
	if (!$last_feat_name) {
		return "000000";
	}
	else {
		$last_feat_name =~ /\d+$/;
		return $&;
	}
}
