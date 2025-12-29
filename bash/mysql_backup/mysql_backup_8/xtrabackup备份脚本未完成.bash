#!/bin/bash
Backup_date=`date +"%Y%m%d"`
log_dir='/opt/mysqlbackup/log'
mkdir -p /backup/mes3-${Backup_date}
mkdir -p $log_dir
old_backfile=`date -d "7 days ago" +%y%m%d`

#全备
xtrabackup --backup \
--user=backup \
--password='Backup!@#123' \
--no-timestamp \
--target-dir=/backup/mes3-${Backup_date} > $log_dir
#删除历史数据
rm -rf /backup/mes3-$old_backfile

#!/bin/bash
#获取当前时间是周几
TIMENOW=$(date +%w)
#上一天是周几
LASTADD=`expr $TIMENOW - 1`
 
if [ $TIMENOW = '0' ]
then
#新建备份文件夹
mkdir -p /backup/full/`date +%y-%m-%d`
else
mkdir -p /backup/add/ad0$TIMENOW/`date +%y-%m-%d`
fi
#获取最近的全量备份目录
full_last_dir=`ls /backup/full -t |head -n 1`
#获取新创建的增量备份目录
add_last_dir=`ls /backup/add/ad0$TIMENOW -t |head -n 1`
#赋值备份路径给变量
full_data=/backup/full/$full_last_dir
add_data=/backup/add/ad0$TIMENOW/$add_last_dir
#如果是周日，执行全量备份
if [ $TIMENOW = '0' ]
    then
        #全量备份数据
        xtrabackup --backup --user=backup --password='Backup!@#123' --no-timestamp --target-dir=$full_data
        if [ $? -eq 0 ]
        then
                echo "备份成功，执行历史备份数据删除"
                #删除历史数据
                find /backup/full -mtime +9 -name "*.*" -exec rm -rf {} \;
        else
                echo "警告，备份数据失败"
        fi
 
#增量备份数据
else
#找到上一次备份的最新目录/如果一个周期内只有一个备份文件，可以不需要这条命令
add_yesterday_dir=`ls /backup/add/ad0$LASTADD -t |head -n 1`
#获取上一次增量备份目录
last_add_data=/backup/add/ad0$LASTADD/$add_yesterday_dir
#获取上一个周期的增量备份文件夹
old_addfile=`date -d "7 days ago" +%y-%m-%d`
 
        #执行增量备份
        if [ $TIMENOW = '1' ]
                then
                xtrabackup --backup --user=backup --password='Backup!@#123' --target-dir=$add_data --incremental-basedir=$full_data
        else
                #获取临时文件夹变量，指定到上一次增量文件夹中
                xtrabackup --backup --user=backup --password='Backup!@#123' --target-dir=$add_data  --incremental-basedir=$last_add_data
        fi   
        if [ $? -eq 0 ]
                then
                echo "备份成功，执行历史备份数据删除"
                #删除历史数据
                rm -rf /backup/add/ad0$TIMENOW/$old_addfile
        else
                echo "警告，备份数据失败"
        fi
fi   
