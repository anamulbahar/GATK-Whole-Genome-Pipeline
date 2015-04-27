#! /bin/bash

# This script was created to run the GATK germline variant calling best pratices pipeline.
# The pipeline takes unprocessed bam file(s) as input and outputs the biological genomic variance
# of the input to a given reference

# Run the GATKsetup.sh script first. See the associated README

# stderr redirected to descriptively named files.report

set -e
set -x
set -o pipefail

cd ~

# Set $RAM to use for all java processes
RAM=-Xmx200g
# Set number of threads to the number of cores/machine for speed optimization
THREADS=32
# Set the dir for the reference files and input bam
dir=/data
# Set the reference fasta
# CHECK LINE 83 OR THERE-ABOUTS, IT POINTS TO A REFERENCE NOT INCLUDED IN THIS VAR
ref=hs37d5.fa

cd ${dir}
# get input bam file
#~/s3cmd/s3cmd get s3://bd2k-test-data/$INPUT1.mapped.ILLUMINA.bwa.CEU.high_coverage_pcr_free.20130906.bam

#NA12878 chr20 bam
wget ftp://ftp-trace.ncbi.nih.gov/1000genomes/ftp/data/NA12878/alignment/NA12878.chrom20.ILLUMINA.bwa.CEU.low_coverage.20121211.bam

# Create Variable for input file
#INPUT1=$INPUT1.mapped.ILLUMINA.bwa.CEU.high_coverage_pcr_free.20130906
INPUT1=NA12878.chrom20.ILLUMINA.bwa.CEU.low_coverage.20121211.bam

# index bam file
samtools index ${dir}/$INPUT1

cd ~

#START PIPELINE
# calculate flag stats using samtools
time samtools flagstat \
    ${dir}/$INPUT1

# sort reads in picard
time java $RAM \
    -jar ~/picard/picard.jar \
    SortSam \
    INPUT=${dir}/$INPUT1 \
    OUTPUT=${dir}/$INPUT1.sorted.bam \
    SORT_ORDER=coordinate
    > sortReads.report 2>&1
rm -r ${dir}/$INPUT1

# mark duplicates reads in picard
time java $RAM \
    -jar ~/picard/picard.jar \
    MarkDuplicates \
    INPUT=${dir}/$INPUT1.sorted.bam \
    OUTPUT=${dir}/$INPUT1.mkdups.bam \
    METRICS_FILE=metrics.txt \
    ASSUME_SORTED=true
    > markDups.report 2>&1
rm -r ${dir}/$INPUT1.sorted.bam

# GATK Indel Realignment
# There are 2 steps to the realignment process
# 1. Determining (small) suspicious intervals which are likely in need of realignment (RealignerTargetCreator)
# 2. Running the realigner over those intervals (IndelRealigner)

# index reference genome, There's no need for this, we have the .fai file
# samtools faidx ${dir}/${ref}

# create sequence dictionary for reference genome
# We could skip this step. I've download the b37.dict

java $RAM \
    -jar ~/picard/picard.jar \
    CreateSequenceDictionary \
    REFERENCE=${dir}/${ref} \
    OUTPUT=${dir}/hs37d5.dict
    #OUTPUT=${dir}/human_g1k_v37.dict
    #OUTPUT=${dir}/${ref}.dict

# Index the markdups.bam for realignment
samtools index ${dir}/$INPUT1.mkdups.bam

# create target indels (find areas likely in need of realignment)
time java $RAM \
    -jar ~/GenomeAnalysisTK.jar \
    -T RealignerTargetCreator \
    -known ${dir}/Mills_and_1000G_gold_standard.indels.b37.vcf \
    -known ${dir}/1000G_phase1.indels.b37.vcf \
    -R ${dir}/${ref} \
    -I ${dir}/$INPUT1.mkdups.bam \
    -o ${dir}/target_intervals.list \
    -nt $THREADS
    > targetIndels.report 2>&1

# realign reads
time java $RAM \
    -jar ~/GenomeAnalysisTK.jar \
    -T IndelRealigner \
    -known ${dir}/Mills_and_1000G_gold_standard.indels.b37.vcf \
    -known ${dir}/1000G_phase1.indels.b37.vcf \
    -R ${dir}/${ref} \
    -targetIntervals ${dir}/target_intervals.list \
    -I ${dir}/$INPUT1.mkdups.bam \
    -o ${dir}/$INPUT1.realigned.bam \
    #-nt $THREADS \ nt is not supported by IndelRealigner
    > realignIndels.report 2>&1
rm -r ${dir}/$INPUT1.mkdups.bam

# GATK BQSR

# create gatk recalibration table
time java $RAM \
    -jar ~/GenomeAnalysisTK.jar \
    -T BaseRecalibrator \
    -R ${dir}/${ref} \
    -I ${dir}/$INPUT1.realigned.bam \
    -knownSites ${dir}/dbsnp_137.b37.vcf \
    -knownSites ${dir}/Mills_and_1000G_gold_standard.indels.b37.vcf \
    -knownSites ${dir}/1000G_phase1.indels.b37.vcf \
    -o ${dir}/recal_data.table \
    -nct $THREADS
    > recalibrationTable.report 2>&1

# recalibrate reads
time java $RAM \
    -jar ~/GenomeAnalysisTK.jar \
    -T PrintReads \
    -R ${dir}/${ref} \
    -I ${dir}/$INPUT1.realigned.bam \
    -BQSR ${dir}/recal_data.table \
    -o ${dir}/$INPUT1.bqsr.bam \
    -nct $THREADS \
    > bqsr.report 2>&1

# GATK VARIANT CALLING
# two stages, check for snps, check for indels
# When these stages are run for multiple bams, uncomment the desired number of -I slots
# 1000Genomes Background BAMS can be run concurrently with UnifiedGenotyper to improve accuracy? (CEU,GBR are the recommended ones)

#snps
time java $RAM \
-jar ~/GenomeAnalysisTK.jar \
-nt $THREADS \
-R ${dir}/${ref} \
-T UnifiedGenotyper \
-I ${dir}/$INPUT1.bqsr.bam \
-o ${dir}/$INPUT1.unified.raw.SNP.gatk.vcf \
-stand_call_conf 30.0 \
-stand_emit_conf 10.0 \
-dcov 200 \
-glm SNP \
> SnpVars.report 2>&1
	#-I $INPUT2.recal.bam \
	#-I $INPUT3.recal.bam \
	#-I $INPUT4.recal.bam \
	#-metrics snps.metrics \
	#-L /b37/target_intervals.bed \ intervals to operate over. See docstring

#indels
time java $RAM \
-jar ~/GenomeAnalysisTK.jar \
-nt $THREADS \
-R ${dir}/${ref} \
-T UnifiedGenotyper \
-I ${dir}/$INPUT1.bqsr.bam \
-o ${dir}/$INPUT1.unified.raw.INDEL.gatk.vcf \
-stand_call_conf 30.0 \
-stand_emit_conf 10.0 \
-dcov 200 \
-glm INDEL \
> indelVars.report 2>&1
	#-I $INPUT2.recal.bam \
	#-I $INPUT3.recal.bam \
	#-I $INPUT4.recal.bam \
	#-metrics snps.metrics \
	#-L /b37/target_intervals.bed \ #see docstring

## GATK VARIANT QUALITY SCORE RECALIBRATION
# Snp Recalibration
java $RAM \
  -jar ~/GenomeAnalysisTK.jar \
  -T VariantRecalibrator \
  -R ${dir}/${ref} \
  -input ${dir}/$INPUT1.unified.raw.SNP.gatk.vcf \
  -nt $THREADS \
  -resource:hapmap,known=false,training=true,truth=true,prior=15.0 ${dir}/hapmap_3.3.b37.vcf \
  -resource:omni,known=false,training=true,truth=true,prior=12.0 ${dir}/1000G_omni2.5.b37.vcf \
  -resource:dbsnp,known=false,training=true,truth=false,prior=6.0 ${dir}/dbsnp_137.b37.vcf \
  -an QD \
  -an DP \
  -an FS \
  -an MQRankSum \
  -mode SNP \
  -recalFile ${dir}/$INPUT1.SNP.recal \
  -tranchesFile ${dir}/$INPUT1.SNP.tranches \
  -rscriptFile ${dir}/$INPUT1.SNP.plots.R \
  > VariantRecalibrator_SNP.report 2>&1
#try simply removing the additional args at the end of 195:197 completely?
# But my current layout is exactly like the docs:https://www.broadinstitute.org/gatk/gatkdocs/org_broadinstitute_gatk_tools_walkers_variantrecalibration_VariantRecalibrator.php


#Apply Snp Recalibration
java $RAM \
  -jar ~/GenomeAnalysisTK.jar \
  -T ApplyRecalibration \
  -input ${dir}/$INPUT1.unified.raw.SNP.gatk.vcf \
  -o ${dir}/$INPUT1.SNP.vqsr.SNP.vcf \
  -R ${dir}/${ref} \
  -nt $THREADS \
  -ts_filter_level 99.0 \
  -tranchesFile ${dir}/$INPUT1.SNP.tranches \
  -recalFile ${dir}/$INPUT1.SNP.recal \
  -mode SNP \
  > ApplyRecalibration_SNP.report 2>&1
  # removed:  -excludeFiltered : TRUE \


#Indel Recalibration
java $RAM \
  -jar ~/GenomeAnalysisTK.jar \
  -T VariantRecalibrator \
  -R ${dir}/${ref} \
  -input ${dir}/$INPUT1.unified.raw.INDEL.gatk.vcf \
  -nt $THREADS \
  -resource:mills,known=false,training=true,truth=true,prior=12.0 ${dir}/Mills_and_1000G_gold_standard.indels.b37.vcf \
  -resource:1000G,known=false,training=true,truth=true,prior=10.0 ${dir}/1000G_phase1.indels.b37.vcf \
  -an QD \
  -an DP \
  -an FS \
  -an MQRankSum \
  -mode INDEL \
  -recalFile ${dir}/$INPUT1.INDEL.recal \
  -tranchesFile ${dir}/$INPUT1.INDEL.tranches \
  -rscriptFile ${dir}/$INPUT1.INDEL.plots.R \
  > VariantRecalibrator_INDEL.report 2>&1

#Apply Indel Recalibration
java $RAM \
  -jar ~/GenomeAnalysisTK.jar \
  -T ApplyRecalibration \
  -input ${dir}/$INPUT1.unified.raw.INDEL.gatk.vcf \
  -o ${dir}/$INPUT1.vqsr_INDEL.vcf \
  -R ${dir}/${ref} \
  -nt $THREADS \
  -ts_filter_level 99.0 \
  -tranchesFile ${dir}/$INPUT1.INDEL.tranches \
  -recalFile ${dir}/$INPUT1.INDEL.recal \
  -mode INDEL \
  > ApplyRecalibration_INDEL.report 2>&1
#removed:  -excludeFiltered : TRUE \

#SELECT VARIANTS
#These steps remove the background files and output SNP and INDEL files, then combine them into a single VCF file

#Select Snp
java $RAM \
  -jar ~/GenomeAnalysisTK.jar \
  -T SelectVariants \
  -R ${dir}/${ref} \
  --variant ${dir}/$INPUT1.SNP.vqsr.SNP.vcf \
  -o ${dir}/output_selected_SNP.file \
  > SelectVariants_SNP.report 2>&1

#Select Indel
java $RAM \
  -jar ~/GenomeAnalysisTK.jar \
  -T SelectVariants \
  -R ${dir}/${ref} \
  --variant ${dir}/$INPUT1.vqsr_INDEL.vcf \
  -o ${dir}/output_Selected_INDEL.file \
  > SelectVariants_INDEL.report 2>&1

#Combine Variants
java $RAM \
  -jar ~/GenomeAnalysisTK.jar \
  -T CombineVariants \
  -R ${dir}/${ref} \
  --variant INDEL_variant \
  --variant ${dir}/output_Selected_INDEL.file \
  --variant ${dir}/output_Selected_SNP.file \
  -o ${dir}/Final_combined_variants.vcf \
  > CombineVarients.report 2>&1
