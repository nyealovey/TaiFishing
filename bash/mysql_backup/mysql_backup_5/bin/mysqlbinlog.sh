#!/bin/bash
# Name:zbk增量备份
# mysql zbk scripts
# By zxsdw.com
# Last modify:2015-01-21

#conf_file="/home/xinhua/mysqlbackup/conf/mysql_increment_hot_backup.conf"
conf_file="/mysql_backup/conf/mysql_increment_hot_backup.conf"

#定义数据库用户名及密码
user=`sed '/^user=/!d;s/.*=//' $conf_file`
userPWD=`sed '/^password=/!d;s/.*=//' $conf_file`
#定义数据库
database=chint_mes
#生成一个新的mysql-bin.00000X文件，如果err日志被清除，则自动新建一个。
mysqladmin -u$user -p$userPWD flush-logs
#定义增量备份位置
daily_databakDir=`sed '/^backup_dir=/!d;s/.*=//' $conf_file`/binlog
#定义MYSQL数据日志目录
mysqlDataDir=/data/mysql
#定义增量日志及目录
eMailFile=$daily_databakDir/log.txt
#eMail=admin@zxsdw.com
#定义变量DATE格式为20150127
#DATE=`date +%Y%m%d`
# 备份日期(年月日)
backup_date=`date +%F`
# 备份日期(时分秒)
backup_time=`date +%H-%M-%S`
# 备份日期(星期)
backup_week_day=`date +%u`

#定义一个总的logFile日志
logFile=$daily_databakDir/mysql_${backup_date}_${backup_time}_${backup_week_day}.log
#美化日志模板
echo "       " >> $eMailFile
echo "-----------------------" >> $eMailFile
#时间格式为15-01-27 01:06:17
echo $(date +"%y-%m-%d %H:%M:%S") >> $eMailFile
echo "-------------------------" >> $eMailFile


#定义删除bin日志的时间范围，格式为20150124010540
TIME=$(date "-d 15 minute ago" +%Y%m%d%H%M%S)
#定义需要增量备份数据的时间范围，格式为2015-01-26 01:04:11
StartTime=$(date "-d 15 minute ago" +"%Y-%m-%d %H:%M:%S")

###########开始删除操作美化日志标题##############
echo "Delete 15 minute before the log" >>$eMailFile

#删除三天前的bin文件，及更新index里的索引记录，美化日志标题
mysql -u$user -p$userPWD -e "purge master logs before ${TIME}" && echo "delete 15 minute before log" |tee -a $eMailFile

#查找index索引里的bin 2进制文件并赋值给 i。
filename=`cat $mysqlDataDir/mysql-bin.index |awk -F "/" '{print $2}'`
for i in $filename
do
#########开始增量备份操作，美化日志标题###########
echo "$StartTime start backup binlog" >> $eMailFile

#利用mysqlbinlog备份1天前增加的数据，并gzip压缩打包到增量备份目录
mysqlbinlog -u$user -p$userPWD --start-datetime="$StartTime" $mysqlDataDir/$i |gzip >> $daily_databakDir/binlog_${backup_date}_${backup_time}_${backup_week_day}.sql.gz |tee -a $eMailFile

done


#如果以上备份脚本执行成功，接着运行下面的删除脚本
if [ $? = 0 ]
then
# 删除mtime>32的增量日志备份文件
find $daily_databakDir -name "*.log" -type f -mtime +0 -exec rm {} \; > /dev/null 2>&1
find $daily_databakDir -name "*.gz" -type f -mtime +0 -exec rm {} \; > /dev/null 2>&1
cd $daily_databakDir
echo "Daily backup succeed" >> $eMailFile
else
echo "Daily backup fail" >> $eMailFile
#mail -s "MySQL Backup" $eMail < $eMailFile #备份失败之后发送邮件通知
#fi结束IF判断
fi


#把变量eMailFile的内容替换logFile内容
cat $eMailFile > $logFile

#如果上面的IF判断失败，再次运行删除mtime>32的增量日志备份文件
find $daily_databakDir -name "*.log" -type f -mtime +0 -exec rm {} \; > /dev/null 2>&1
find $daily_databakDir -name "*.gz" -type f -mtime +0 -exec rm {} \; > /dev/null 2>&1

