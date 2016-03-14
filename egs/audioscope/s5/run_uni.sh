#!/bin/bash

#
# Copyright 2013 Bagher BabaAli,
#           2014 Brno University of Technology (Author: Karel Vesely)
#           2014 Jan Chorowski
#
# Audioscope: a database of Polish audiobooks.
#

#
# Run on the best file selection from SPhinx
#
#


. ./cmd.sh
[ -f path.sh ] && . ./path.sh
set -e
#set -x

# Acoustic model parameters
numLeavesTri1=2500
numGaussTri1=15000
numLeavesMLLT=2500
numGaussMLLT=15000
numLeavesSAT=2500
numGaussSAT=15000
numGaussUBM=400
numLeavesSGMM=7000
numGaussSGMM=9000

feats_nj=16
train_nj=16
decode_nj=2

echo ============================================================================
echo "                Data & Lexicon & Language Preparation                     "
echo ============================================================================

audioscope=/pio/data/data/audioscope
dev_set=/home/jch/scratch/korpusiki/eksperci
test_set=/pio/scratch/1/i246062/data/test_set
models=/pio/scratch/1/i246062/l_models/test_models
audiobooks=/pio/data/data/audioscope/voice/audiobooks/all

local/audioscope_data_prep_uni.sh $audioscope $audiobooks $dev_set $test_set || exit 1

# Get lm suffixes
source data/lm_suffixes.sh

local/audioscope_prepare_dict_ultimate.sh $models

# Insert optional-silence with probability 0.5, which is the
# default.
for lm_suffix in "${LM_SUFFIXES[@]}"
do
  utils/prepare_lang.sh --position-dependent-phones false --num-sil-states 3 \
   data/local/dict/dict_${lm_suffix} "sil" data/local/lang_tmp_${lm_suffix} \
   data/lang_test_${lm_suffix}
done

local/audioscope_format_data_ttd.sh

echo ============================================================================
echo "         MFCC Feature Extration & CMVN for Training and Test set           "
echo ============================================================================

# Now make MFCC features.
mfccdir=mfcc


for x in train dev test; do
  for y in phones words; do
    steps/make_mfcc.sh --cmd "$train_cmd" --nj $feats_nj data/${x}_${y} exp/make_mfcc/${x}_${y} $mfccdir
    steps/compute_cmvn_stats.sh data/${x}_${y} exp/make_mfcc/${x}_${y} $mfccdir
  done
done

echo ============================================================================
echo "                     MonoPhone Training & Decoding                        "
echo ============================================================================

steps/train_mono.sh  --nj "$train_nj" --cmd "$train_cmd" data/train_phones data/lang exp/mono

for lm_suffix in "${LM_SUFFIXES[@]}"
do
  echo " -- For LM: $lm_suffix..."

  if [ $lm_suffix == "bg" ]; then
    ttd_suffix="phones"
  else
    ttd_suffix="words"
  fi

  utils/mkgraph.sh --mono data/lang_test_${lm_suffix} exp/mono exp/mono/graph_${lm_suffix}

  steps/decode.sh --nj "$decode_nj" --cmd "$decode_cmd" \
   exp/mono/graph_${lm_suffix} data/dev_${ttd_suffix} exp/mono/decode_dev_${lm_suffix}

  steps/decode.sh --nj "$decode_nj" --cmd "$decode_cmd" \
   exp/mono/graph_${lm_suffix} data/test_${ttd_suffix} exp/mono/decode_test_${lm_suffix}
done

echo ============================================================================
echo "           tri1 : Deltas + Delta-Deltas Training & Decoding               "
echo ============================================================================

steps/align_si.sh --boost-silence 1.25 --nj "$train_nj" --cmd "$train_cmd" \
 data/train_phones data/lang exp/mono exp/mono_ali

# Train tri1, which is deltas + delta-deltas, on train data.
steps/train_deltas.sh --cmd "$train_cmd" \
 $numLeavesTri1 $numGaussTri1 data/train_phones data/lang exp/mono_ali exp/tri1

for lm_suffix in "${LM_SUFFIXES[@]}"
do
  echo " -- For LM: $lm_suffix..."

  if [ $lm_suffix == "bg" ]; then
    ttd_suffix="phones"
  else
    ttd_suffix="words"
  fi

  utils/mkgraph.sh data/lang_test_${lm_suffix} exp/tri1 exp/tri1/graph_${lm_suffix}

  steps/decode.sh --nj "$decode_nj" --cmd "$decode_cmd" \
   exp/tri1/graph_${lm_suffix} data/dev_${ttd_suffix} exp/tri1/decode_dev_${lm_suffix}

  steps/decode.sh --nj "$decode_nj" --cmd "$decode_cmd" \
   exp/tri1/graph_${lm_suffix} data/test_${ttd_suffix} exp/tri1/decode_test_${lm_suffix}
done

echo ============================================================================
echo "                 tri2 : LDA + MLLT Training & Decoding                    "
echo ============================================================================

steps/align_si.sh --nj "$train_nj" --cmd "$train_cmd" \
  data/train_phones data/lang exp/tri1 exp/tri1_ali

steps/train_lda_mllt.sh --cmd "$train_cmd" \
 --splice-opts "--left-context=3 --right-context=3" \
 $numLeavesMLLT $numGaussMLLT data/train_phones data/lang exp/tri1_ali exp/tri2

for lm_suffix in "${LM_SUFFIXES[@]}"
do
  echo " -- For LM: $lm_suffix..."

  if [ $lm_suffix == "bg" ]; then
    ttd_suffix="phones"
  else
    ttd_suffix="words"
  fi

  utils/mkgraph.sh data/lang_test_${lm_suffix} exp/tri2 exp/tri2/graph_${lm_suffix}

  steps/decode.sh --nj "$decode_nj" --cmd "$decode_cmd" \
   exp/tri2/graph_${lm_suffix} data/dev_${ttd_suffix} exp/tri2/decode_dev_${lm_suffix}

  steps/decode.sh --nj "$decode_nj" --cmd "$decode_cmd" \
   exp/tri2/graph_${lm_suffix} data/test_${ttd_suffix} exp/tri2/decode_test_${lm_suffix}
done

echo ============================================================================
echo "              tri3 : LDA + MLLT + SAT Training & Decoding                 "
echo ============================================================================

# Align tri2 system with train data.
steps/align_si.sh --nj "$train_nj" --cmd "$train_cmd" \
 --use-graphs true data/train_phones data/lang exp/tri2 exp/tri2_ali

# From tri2 system, train tri3 which is LDA + MLLT + SAT.
steps/train_sat.sh --cmd "$train_cmd" \
 $numLeavesSAT $numGaussSAT data/train_phones data/lang exp/tri2_ali exp/tri3

for lm_suffix in "${LM_SUFFIXES[@]}"
do
  echo " -- For LM: $lm_suffix..."

  if [ $lm_suffix == "bg" ]; then
    ttd_suffix="phones"
  else
    ttd_suffix="words"
  fi

  utils/mkgraph.sh data/lang_test_${lm_suffix} exp/tri3 exp/tri3/graph_${lm_suffix}

  steps/decode_fmllr.sh --nj "$decode_nj" --cmd "$decode_cmd" \
   exp/tri3/graph_${lm_suffix} data/dev_${ttd_suffix} exp/tri3/decode_dev_${lm_suffix}

  steps/decode_fmllr.sh --nj "$decode_nj" --cmd "$decode_cmd" \
   exp/tri3/graph_${lm_suffix} data/test_${ttd_suffix} exp/tri3/decode_test_${lm_suffix}
done

echo ============================================================================
echo "                        SGMM2 Training & Decoding                         "
echo ============================================================================

steps/align_fmllr.sh --nj "$train_nj" --cmd "$train_cmd" \
 data/train_phones data/lang exp/tri3 exp/tri3_ali

#exit 0 # From this point you can run DNN : local/run_dnn.sh

steps/train_ubm.sh --cmd "$train_cmd" \
 $numGaussUBM data/train_phones data/lang exp/tri3_ali exp/ubm4

steps/train_sgmm2.sh --cmd "$train_cmd" $numLeavesSGMM $numGaussSGMM \
 data/train_phones data/lang exp/tri3_ali exp/ubm4/final.ubm exp/sgmm2_4

for lm_suffix in "${LM_SUFFIXES[@]}"
do
  echo " -- For LM: $lm_suffix..."

  if [ $lm_suffix == "bg" ]; then
    ttd_suffix="phones"
  else
    ttd_suffix="words"
  fi

  utils/mkgraph.sh data/lang_test_${lm_suffix} exp/sgmm2_4 exp/sgmm2_4/graph_${lm_suffix}

  steps/decode_sgmm2.sh --nj "$decode_nj" --cmd "$decode_cmd" \
   --transform-dir exp/tri3/decode_dev_${lm_suffix} \
   exp/sgmm2_4/graph_${lm_suffix} data/dev_${ttd_suffix} exp/sgmm2_4/decode_dev_${lm_suffix}

  steps/decode_sgmm2.sh --nj "$decode_nj" --cmd "$decode_cmd" \
   --transform-dir exp/tri3/decode_test_${lm_suffix} \
   exp/sgmm2_4/graph_${lm_suffix} data/test_${ttd_suffix} exp/sgmm2_4/decode_test_${lm_suffix}
done

echo ============================================================================
echo "                    MMI + SGMM2 Training & Decoding                       "
echo ============================================================================

steps/align_sgmm2.sh --nj "$train_nj" --cmd "$train_cmd" \
 --transform-dir exp/tri3_ali --use-graphs true --use-gselect true \
 data/train_phones data/lang exp/sgmm2_4 exp/sgmm2_4_ali

steps/make_denlats_sgmm2.sh --nj "$train_nj" --sub-split "$train_nj" \
 --acwt 0.2 --lattice-beam 10.0 --beam 18.0 \
 --cmd "$decode_cmd" --transform-dir exp/tri3_ali \
 data/train_phones data/lang exp/sgmm2_4_ali exp/sgmm2_4_denlats

steps/train_mmi_sgmm2.sh --acwt 0.2 --cmd "$decode_cmd" \
 --transform-dir exp/tri3_ali --boost 0.1 --drop-frames true \
 data/train_phones data/lang exp/sgmm2_4_ali exp/sgmm2_4_denlats exp/sgmm2_4_mmi_b0.1

for lm_suffix in "${LM_SUFFIXES[@]}"
do
  if [ $lm_suffix == "bg" ]; then
    ttd_suffix="phones"
  else
    ttd_suffix="words"
  fi

  for iter in 1 2 3 4; do
    steps/decode_sgmm2_rescore.sh --cmd "$decode_cmd" --iter $iter \
     --transform-dir exp/tri3/decode_dev_${lm_suffix} \
     data/lang_test_${lm_suffix} data/dev_${ttd_suffix} exp/sgmm2_4/decode_dev_${lm_suffix} \
     exp/sgmm2_4_mmi_b0.1/decode_dev_it${iter}_${lm_suffix}

    steps/decode_sgmm2_rescore.sh --cmd "$decode_cmd" --iter $iter \
     --transform-dir exp/tri3/decode_test_${lm_suffix} \
     data/lang_test_${lm_suffix} data/test_${ttd_suffix} exp/sgmm2_4/decode_test_${lm_suffix} \
     exp/sgmm2_4_mmi_b0.1/decode_test_it${iter}_${lm_suffix}
  done
done

echo ============================================================================
echo "                    DNN Hybrid Training & Decoding                        "
echo ============================================================================

# DNN hybrid system training parameters
dnn_mem_reqs="mem_free=1.0G,ram_free=0.2G"
dnn_extra_opts="--num_epochs 20 --num-epochs-extra 10 --add-layers-period 1 --shrink-interval 3"

steps/nnet2/train_tanh.sh --mix-up 5000 --initial-learning-rate 0.015 \
  --final-learning-rate 0.002 --num-hidden-layers 2  \
  --num-jobs-nnet "$train_nj" --cmd "$train_cmd" "${dnn_train_extra_opts[@]}" \
  data/train_phones data/lang exp/tri3_ali exp/tri4_nnet

for lm_suffix in "${LM_SUFFIXES[@]}"
do
  if [ $lm_suffix == "bg" ]; then
    ttd_suffix="phones"
  else
    ttd_suffix="words"
  fi

  [ ! -d exp/tri4_nnet/decode_dev_${lm_suffix} ] && mkdir -p exp/tri4_nnet/decode_dev_${lm_suffix}
  decode_extra_opts=(--num-threads 6 --parallel-opts "-pe smp 6 -l mem_free=4G,ram_free=0.7G")
  steps/nnet2/decode.sh --cmd "$decode_cmd" --nj "$decode_nj" "${decode_extra_opts[@]}" \
    --transform-dir exp/tri3/decode_dev_${lm_suffix} exp/tri3/graph_${lm_suffix} data/dev_${ttd_suffix} \
    exp/tri4_nnet/decode_dev_${lm_suffix} | tee exp/tri4_nnet/decode_dev_${lm_suffix}/decode.log

  [ ! -d exp/tri4_nnet/decode_test_${lm_suffix} ] && mkdir -p exp/tri4_nnet/decode_test_${lm_suffix}
  steps/nnet2/decode.sh --cmd "$decode_cmd" --nj "$decode_nj" "${decode_extra_opts[@]}" \
    --transform-dir exp/tri3/decode_test_${lm_suffix} exp/tri3/graph_${lm_suffix} data/test_${ttd_suffix} \
    exp/tri4_nnet/decode_test_${lm_suffix} | tee exp/tri4_nnet/decode_test_${lm_suffix}/decode.log
done

echo ============================================================================
echo "                    System Combination (DNN+SGMM)                         "
echo ============================================================================

for lm_suffix in "${LM_SUFFIXES[@]}"
do
  if [ $lm_suffix == "bg" ]; then
    ttd_suffix="phones"
  else
    ttd_suffix="words"
  fi

  for iter in 1 2 3 4; do
    local/score_combine.sh --cmd "$decode_cmd" \
     data/dev_${ttd_suffix} data/lang_test_${lm_suffix} exp/tri4_nnet/decode_dev_${lm_suffix} \
     exp/sgmm2_4_mmi_b0.1/decode_dev_it${iter}_${lm_suffix} \
     exp/combine_2/decode_dev_it${iter}_${lm_suffix}

    local/score_combine.sh --cmd "$decode_cmd" \
     data/test_${ttd_suffix} data/lang_test_${lm_suffix} exp/tri4_nnet/decode_test_${lm_suffix} \
     exp/sgmm2_4_mmi_b0.1/decode_test_it${iter}_${lm_suffix} \
     exp/combine_2/decode_test_it${iter}_${lm_suffix}
  done
done

echo ============================================================================
echo "                    Getting Results [see RESULTS file]                    "
echo ============================================================================

bash RESULTS dev
bash RESULTS test

echo ============================================================================
echo "Finished successfully on" `date`
echo ============================================================================

exit 0