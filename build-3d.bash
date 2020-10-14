#!/bin/bash

# req: JOB_ID // SLURM_ARRAY_JOB_ID
# req: SGE_TASK_ID // SLURM_ARRAY_TASK_ID
# req: INPUT
# req: OUTPUT
# req: LOGGING

# opt: WORK_DIR

cwd=$PWD
export TEMPDIR=${TEMPDIR-/tmp}
export WORK_DIR=${WORK_DIR-$TEMPDIR/build_3d}
export OLD_DOCK_VERSION=${OLD_DOCK_VERSION-DOCK.2.5.1}
export DOCK_VERSION=${DOCK_VERSION-DOCK.2.5.2}
export OLD_PYENV_VERSION=${OLD_PYENV_VERSION-lig_build_py3-3.7}
export PYENV_VERSION=${PYENV_VERSION-lig_build_py3-3.7.1}
export PYTHONBASE=$WORK_DIR/$PYENV_VERSION
export DOCKBASE=$WORK_DIR/${DOCK_VERSION}

JOB_ID=${SLURM_ARRAY_JOB_ID-$JOB_ID}
TASK_ID=${SLURM_ARRAY_TASK_ID-$SGE_TASK_ID}

if [ -z $SLURM_ARRAY_JOB_ID ]; then
        ERROR_LOG=$TEMPDIR/batch_3d.e${JOB_ID}.${TASK_ID}
        OUTPUT_LOG=$TEMPDIR/batch_3d.o${JOB_ID}.${TASK_ID}
else
        ERROR_LOG=$TEMPDIR/batch_3d_${JOB_ID}_${TASK_ID}.err
        OUTPUT_LOG=$TEMPDIR/batch_3d_${JOB_ID}_${TASK_ID}.out
fi

mkdir -p $WORK_DIR

function synchronize_all_but_first {
        if [ -f /tmp/${1}.done ]; then 
		if [ $(( (`date +%s` - `stat -L --format %Y /tmp/${1}.done`) > (10) )) ]; then
			rm /tmp/${1}.done
		else
			return;
		fi
	fi # in the case of a particularly short running command, it might be done by the time another job even enters this function
        flock -w 0 /tmp/${1}.lock -c "printf ${1} && ${@:2} && echo > /tmp/${1}.done" && FIRST=TRUE
        if [ -z $FIRST ]; then
                printf "waiting ${1}"
                while ! [ -f /tmp/${1}.done ]; do sleep 1; printf "."; done
        else
                sleep 5 && rm /tmp/${1}.done
        fi
	echo
}

# any jobs that were cancelled previously should be cleaned up
old_work=$(find $WORK_DIR -mindepth 1 -maxdepth 1 -mmin +180 -name '*.build-3d.d')

# to properly synchronize work done by multiple threads we need to do a couple things
# 1. we need a long-term flag to mark the work as completed/not completed
#    a. In the case of removing old files, this "flag" might be as simple as there no longer being old files present
#    b. In the case of an install/extract operation, this would be a ".done" file in the install directory
# 2. local synchronization
#    a. It doesn't serve us well to have multiple threads trying to extract/remove the same file at the same time
#       To prevent this it helps to use a flock lock to ensure that only one process can work on the task at a time
#    b. In the case of an install operation, we might not want other threads to continue until the first thread is done
#       with it's work. In this case, we need to have a temporary "done" flag for the first thread to signal the
#       other waiting threads that it's okay to move on, which is what I do in the synchronize_all_but_first function

if [ $(echo "$old_work" | wc -l) -gt 1 ]; then
        synchronize_all_but_first "removing_old_work" "find $WORK_DIR -mindepth 1 -maxdepth 1 -mmin +120 -name '*.build-3d.d' | xargs rm -r"
fi
if [ -d $WORK_DIR/$OLD_PYENV_VERSION ]; then
        synchronize_all_but_first "removing_old_pyenv" "rm -r $WORK_DIR/$OLD_PYENV_VERSION"
fi
if [ -d $WORK_DIR/$OLD_DOCK_VERSION ]; then
        synchronize_all_but_first "removing_old_dock" "rm -r $WORK_DIR/$OLD_DOCK_VERSION"
fi
if ! [ -f $DOCKBASE/.done ]; then
        synchronize_all_but_first "extracting_dock" "cp $HOME/soft/$DOCK_VERSION.tar.gz $WORK_DIR && pushd $WORK_DIR && time tar -xzf $DOCK_VERSION.tar.gz && echo > $DOCK_VERSION/.done && popd"
fi
if ! [ -f $PYTHONBASE/.done ]; then
        synchronize_all_but_first "extracting_pyenv" "cp $HOME/soft/$PYENV_VERSION.tar.gz $WORK_DIR && pushd $WORK_DIR && time tar -xzf $PYENV_VERSION.tar.gz && echo > $PYENV_VERSION/.done && popd"
fi
if ! [ -f $WORK_DIR/lib/.done ]; then
	synchronize_all_but_first "extracting_libs" "cp $HOME/soft/lib.tar.gz $WORK_DIR && pushd $WORK_DIR && time tar -xzf lib.tar.gz && echo > lib/.done && popd"
fi
if ! [ -f $WORK_DIR/openbabel-install/.done ]; then
	synchronize_all_but_first "extracting_obabel" "cp $HOME/soft/openbabel-install.tar.gz $WORK_DIR && pushd $WORK_DIR && time tar -xzf openbabel-install.tar.gz && echo > openbabel-install/.done && popd"
fi
if ! [ -f $WORK_DIR/jchem-19.15/.done ]; then
        synchronize_all_but_first "extracting_jchem" "cp $HOME/soft/jchem-19.15.tar.gz $WORK_DIR && pushd $WORK_DIR && time tar -xzf jchem-19.15.tar.gz && echo > jchem-19.15/.done && popd"
fi
if ! [ -f $WORK_DIR/corina/.done ]; then
	synchronize_all_but_first "extracting_corina" "cp $HOME/soft/corina.tar.gz $WORK_DIR && pushd $WORK_DIR && time tar -xzf corina.tar.gz && echo > corina/.done && popd"
fi

function log {
    echo "[build-3d $(date +%X)]: $@"
}

log $(hostname)

WORK_BASE=$WORK_DIR/${JOB_ID}_${TASK_ID}.build-3d.d
mkdir -p $WORK_BASE

if [ -z $RESUBMIT ]; then
	SPLIT_FILE=$INPUT/`ls $INPUT | tr '\n' ' ' | cut -d' ' -f$TASK_ID`
	TARGET_FILE=$WORK_BASE/$TASK_ID
else
	SPLIT_FILE=$INPUT/resubmit/`ls $INPUT/resubmit | tr '\n' ' ' | cut -d' ' -f$TASK_ID`
	TARGET_FILE=$WORK_BASE/$(basename $SPLIT_FILE)
fi

cp $SPLIT_FILE $TARGET_FILE
log SPLIT_FILE=$SPLIT_FILE
cd $WORK_BASE

log $(hostname)
log "starting build job on $TARGET_FILE"
log "len($TARGET_FILE)=$(cat $TARGET_FILE | wc -l)"

# move logs to their final destination & clean up the working directory
cleanup() {
        mv $ERROR_LOG $LOGGING/$(basename $TARGET_FILE).err
        mv $OUTPUT_LOG $LOGGING/$(basename $TARGET_FILE).out
        if [ -z $SKIP_DELETE ] && [ -d $WORK_BASE ]; then rm -r $WORK_BASE; fi
        exit
}

# save our progress if we've reached the time limit. DOCK has not been modified to take advantage of this, so this doesn't do much as of yet
# but this will be useful for re-doing as little work as possible in the future
reached_time_limit() {
	pushd $WORK_BASE
        log "time limit reached! saving progress..."
        tar -czf $(basename $TARGET_FILE).save.tar.gz .
        mkdir -p $OUTPUT/save
        mv $(basename $TARGET_FILE).save.tar.gz $OUTPUT/save
        popd $WORK_BASE
	cleanup
}

# on sge, SIGUSR1 is sent once a job surpasses it's "soft" time limit (-l s_rt=XX:XX:XX), usually specified a minute or two before the hard time limit (-l h_rt=XX:XX:XX) where SIGTERM is sent
# on slurm, the same can be achieved by adding the --signal=USR1@60 option to your sbatch args to send the SIGUSR1 signal 1 minute before the job is terminated
trap reached_time_limit SIGUSR1

# jobs that have output already shouldn't be resubmitted, but this is just in case that doesn't happen
if [ -f $OUTPUT/$(basename $TARGET_FILE).tar.gz ]; then
        log "results already present in $OUTPUT_BASE for this job, exiting..."
        cleanup
fi

# un-archive our saved progress (if any) into the current working directory
if [ -f $OUTPUT/save/$(basename $TARGET_FILE).save.tar.gz ]; then
        echo "saved progress found!"
	tar -xzf $OUTPUT/save/$(basename $TARGET_FILE).save.tar.gz .
        rm $OUTPUT/save/$(basename $TARGET_FILE).save.tar.gz
	pwd
	ls -l
fi

source $cwd/env_new_lig_build.sh
export DEBUG=TRUE
# this env variable used for debugging old versions only
MAIN_SCRIPT_NAME=${MAIN_SCRIPT_NAME-build_database_ligand_strain_noH_btingle.sh}
${DOCKBASE}/ligand/generate/$MAIN_SCRIPT_NAME -H 7.4 --no-db $(basename $TARGET_FILE)

log "finished build job on $TARGET_FILE"
mv working/output.tar.gz $OUTPUT/$(basename $TARGET_FILE).tar.gz
cleanup
