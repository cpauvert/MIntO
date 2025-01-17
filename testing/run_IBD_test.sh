#!/usr/bin/env bash

# Which MIntO version are we using?
# Use specific tag by "tags/<TAG>" or "main"
# E.g.
# MINTO_STABLE_VERSION="tags/2.0.0"
# Developers use 'main' but users should stick to stable versions.

MINTO_STABLE_VERSION="tags/2.0.0"

# Set MIntO and scratch locations

if [ ! -z "$COMPUTEROME_PROJ" ]; then
  # Danish computerome resource
  SHADOWDIR="/home/projects/$COMPUTEROME_PROJ/scratch/$USER/MIntO/"
  MINTO_DIR="/home/projects/$COMPUTEROME_PROJ/apps/MIntO"
else
  SHADOWDIR="/scratch/$USER/tmp/MIntO/"
  MINTO_DIR="$(pwd)/MIntO"
fi
CONDA_DIR="$MINTO_DIR/conda_env"

# Where will the tutorial be tested?

TEST_DIR=$(pwd)

# Get MIntO or pull the latest if it already exists

echo "-------------"
echo "GETTING MINTO"
echo "-------------"

if [ -d "$MINTO_DIR" ]; then
  cd $MINTO_DIR
  git checkout main
  git pull
  git checkout $MINTO_STABLE_VERSION
  cd $TEST_DIR
else
  cd $(dirname $MINTO_DIR)
  git clone https://github.com/arumugamlab/MIntO.git
  cd MIntO
  git checkout $MINTO_STABLE_VERSION
  cd $TEST_DIR
fi

# Record the snakemake commands that have been run

COMMAND_LOG='commands_dependencies.txt'

# Snakemake options
if [ ! -z "$COMPUTEROME_PROJ" ]; then
  SNAKE_PARAMS="--use-conda --restart-times 1 --keep-going --latency-wait 60 --conda-prefix $CONDA_DIR --shadow-prefix $SHADOWDIR --jobs 16 --default-resources gpu=0 mem=4 --cluster 'qsub -d $(pwd) -W group_list=$COMPUTEROME_PROJ -A $COMPUTEROME_PROJ -N {name} -l nodes=1:thinnode:ppn={threads},mem={resources.mem}gb,walltime=7200 -V -v TMPDIR=$SHADOWDIR' --local-cores 4"
else
  # Computerome thin nodes
  #SNAKE_PARAMS="--use-conda --restart-times 1 --keep-going --latency-wait 60 --conda-prefix $CONDA_DIR --shadow-prefix $SHADOWDIR --jobs 16 --cores 40 --resources mem=188"
  # Default
  SNAKE_PARAMS="--use-conda --restart-times 1 --keep-going --latency-wait 60 --conda-prefix $CONDA_DIR --shadow-prefix $SHADOWDIR --jobs 16 --cores 96 --resources mem=700"
fi

# Set code directory
CODE_DIR=$MINTO_DIR

# Download dependencies

echo ""
echo "------------"
echo "DEPENDENCIES"
echo "------------"

cat $MINTO_DIR/testing/dependencies.yaml.in | sed "s@<__MINTO_DIR__>@$MINTO_DIR@;s@<__TEST_DIR__>@$TEST_DIR@" > dependencies.yaml
cmd="snakemake --snakefile $CODE_DIR/smk/dependencies.smk --configfile dependencies.yaml $SNAKE_PARAMS >& dependencies.log"
echo $cmd > $COMMAND_LOG
time (eval $cmd && echo "OK")

# Download raw data

echo ""
echo "-------------"
echo "TUTORIAL DATA"
echo "-------------"

if [ ! -d "IBD_tutorial_raw" ]; then
  echo -n "Downloading tutorial data: "
  wget --quiet https://zenodo.org/record/8320216/files/IBD_tutorial_raw_v2.0.0.tar.gz
  tar xfz IBD_tutorial_raw_v2.0.0.tar.gz
  echo "OK"
fi
echo ""

# Extract ref-genome

tar xfz $MINTO_DIR/tutorial/genomes.tar.gz

# Extract gene-catalog

tar xfz $MINTO_DIR/tutorial/gene_catalog.tar.gz

# Get data
mkdir -p IBD_tutorial
cd IBD_tutorial
cp $MINTO_DIR/tutorial/metadata/tutorial_metadata.txt .
cp $MINTO_DIR/tutorial/build_hg18_subset.fna .

# Run metaG and metaT steps

echo "---------------"
echo "DATA PROCESSING"
echo "---------------"

OMICS="metaG"
for OMICS in metaG metaT; do
  echo ""
  echo "------------------"
  echo "Processing $OMICS:"
  echo "------------------"
  mkdir -p $OMICS
  cd $OMICS

  COMMAND_LOG="commands_${OMICS}.txt"

  echo -n "QC_1: "
  cat $MINTO_DIR/testing/QC_1.yaml.in | sed "s@<__MINTO_DIR__>@$MINTO_DIR@;s@<__TEST_DIR__>@$TEST_DIR@;s@<__OMICS__>@$OMICS@;" > QC_1.yaml
  cmd="snakemake --snakefile $CODE_DIR/smk/QC_1.smk --configfile QC_1.yaml $SNAKE_PARAMS >& QC_1.log"
  echo $cmd >> $COMMAND_LOG
  time (eval $cmd && echo "OK")

  if [ ! -f "QC_2.yaml.fixed" ]; then
    patch QC_2.yaml $CODE_DIR/testing/QC_2.patch -o - | sed "s@<__MINTO_DIR__>@$MINTO_DIR@;s@<__TEST_DIR__>@$TEST_DIR@" > QC_2.yaml.fixed
  fi

  echo -n "QC_2: "
  cmd="snakemake --snakefile $CODE_DIR/smk/QC_2.smk --configfile QC_2.yaml.fixed $SNAKE_PARAMS >& QC_2.log"
  echo $cmd >> $COMMAND_LOG
  time (eval $cmd && echo "OK")

  echo -n "ASSEMBLY: "
  perl -pe "s/enable_COASSEMBLY: no/enable_COASSEMBLY: yes/; s/^# Contig-depth: bwa/EXCLUDE_ASSEMBLY_TYPES:\n - illumina_coas\n\n# Contig-depth: bwa/" < assembly.yaml > assembly.yaml.fixed
  cmd="snakemake --snakefile $CODE_DIR/smk/assembly.smk --configfile assembly.yaml.fixed $SNAKE_PARAMS >& assembly.log"
  echo $cmd >> $COMMAND_LOG
  time (eval $cmd && echo "OK")

  echo -n "BINNING_PREP: "
  cmd="snakemake --snakefile $CODE_DIR/smk/binning_preparation.smk --configfile assembly.yaml.fixed $SNAKE_PARAMS >& binning_prep.log"
  echo $cmd >> $COMMAND_LOG
  time (eval $cmd && echo "OK")

  echo -n "BINNING: "
  cmd="snakemake --snakefile $CODE_DIR/smk/mags_generation.smk --configfile mags_generation.yaml $SNAKE_PARAMS >& mags.log"
  echo $cmd >> $COMMAND_LOG
  time (eval $cmd && echo "OK")

  echo -n "GENE_ANNOTATION - MAG: "
  cmd="snakemake --snakefile $CODE_DIR/smk/gene_annotation.smk --configfile mapping.yaml $SNAKE_PARAMS >& annotation.log"
  echo $cmd >> $COMMAND_LOG
  time (eval $cmd && echo "OK")

  echo -n "GENE_ABUNDANCE - MAG: "
  cmd="snakemake --snakefile $CODE_DIR/smk/gene_abundance.smk --configfile mapping.yaml $SNAKE_PARAMS >& abundance.log"
  echo $cmd >> $COMMAND_LOG
  time (eval $cmd && echo "OK")

  sed "s@map_reference: MAG@map_reference: reference_genome@; s@PATH_reference:@PATH_reference: $TEST_DIR/genomes@;" mapping.yaml > mapping.yaml.refgenome
  echo -n "GENE_ANNOTATION - refgenome: "
  cmd="snakemake --snakefile $CODE_DIR/smk/gene_annotation.smk --configfile mapping.yaml.refgenome $SNAKE_PARAMS >& annotation.refgenome.log"
  echo $cmd >> $COMMAND_LOG
  time (eval $cmd && echo "OK")

  echo -n "GENE_ABUNDANCE - refgenome: "
  cmd="snakemake --snakefile $CODE_DIR/smk/gene_abundance.smk --configfile mapping.yaml.refgenome $SNAKE_PARAMS >& abundance.refgenome.log"
  echo $cmd >> $COMMAND_LOG
  time (eval $cmd && echo "OK")

  echo -n "GENE_ABUNDANCE - gene catalog: "
  sed "s@map_reference: MAG@map_reference: genes_db@; s@PATH_reference:@PATH_reference: $TEST_DIR/gene_catalog@; s@NAME_reference:@NAME_reference: gene_catalog.fna@; s@abundance_normalization: TPM,MG@abundance_normalization: TPM@" mapping.yaml > mapping.yaml.catalog
  cmd="snakemake --snakefile $CODE_DIR/smk/gene_abundance.smk --configfile mapping.yaml.catalog $SNAKE_PARAMS >& abundance.catalog.log"
  echo $cmd >> $COMMAND_LOG
  time (eval $cmd && echo "OK")

  cd ..
done

# Run integration

echo ""
echo ""
echo "----------------"
echo "DATA INTEGRATION"
echo "----------------"

for OMICS in metaG_metaT metaG metaT; do

  echo ""
  echo "------------------"
  echo "Processing $OMICS:"
  echo "------------------"

  COMMAND_LOG="commands_integration_${OMICS}.txt"

  sed "s/omics: metaG_metaT/omics: $OMICS/" data_integration.yaml > data_integration.yaml.MG.$OMICS
  echo -n "MODE - MAG, MG: "
  cmd="snakemake --snakefile $CODE_DIR/smk/data_integration.smk --configfile data_integration.yaml.MG.$OMICS $SNAKE_PARAMS >& integration.MAG.MG.$OMICS.log"
  echo $cmd >> $COMMAND_LOG
  time (eval $cmd && echo "OK")
  sed "s/abundance_normalization: MG/abundance_normalization: TPM/" data_integration.yaml.MG.$OMICS > data_integration.yaml.TPM.$OMICS
  echo -n "MODE - MAG, TPM: "
  cmd="snakemake --snakefile $CODE_DIR/smk/data_integration.smk --configfile data_integration.yaml.TPM.$OMICS $SNAKE_PARAMS >& integration.MAG.TPM.$OMICS.log"
  echo $cmd >> $COMMAND_LOG
  time (eval $cmd && echo "OK")

  echo -n "MODE - refgenome, MG: "
  sed "s/map_reference: MAG/map_reference: reference_genome/" data_integration.yaml.MG.$OMICS > data_integration.yaml.refgenome.MG.$OMICS
  cmd="snakemake --snakefile $CODE_DIR/smk/data_integration.smk --configfile data_integration.yaml.refgenome.MG.$OMICS $SNAKE_PARAMS >& integration.refgenome.MG.$OMICS.log"
  echo $cmd >> $COMMAND_LOG
  time (eval $cmd && echo "OK")
  sed "s/abundance_normalization: MG/abundance_normalization: TPM/" data_integration.yaml.refgenome.MG.$OMICS > data_integration.yaml.refgenome.TPM.$OMICS
  echo -n "MODE - refgenome, TPM: "
  cmd="snakemake --snakefile $CODE_DIR/smk/data_integration.smk --configfile data_integration.yaml.refgenome.TPM.$OMICS $SNAKE_PARAMS >& integration.refgenome.TPM.$OMICS.log"
  echo $cmd >> $COMMAND_LOG
  time (eval $cmd && echo "OK")

  echo -n "MODE - gene-catalog, TPM: "
  sed "s/map_reference: MAG/map_reference: genes_db/; s@ANNOTATION_file:@ANNOTATION_file: $TEST_DIR/gene_catalog/gene_catalog.annotations.tsv@" data_integration.yaml.TPM.$OMICS > data_integration.yaml.catalog.TPM.$OMICS
  cmd="snakemake --snakefile $CODE_DIR/smk/data_integration.smk --configfile data_integration.yaml.catalog.TPM.$OMICS $SNAKE_PARAMS >& integration.catalog.TPM.$OMICS.log"
  echo $cmd >> $COMMAND_LOG
  time (eval $cmd && echo "OK")

done
