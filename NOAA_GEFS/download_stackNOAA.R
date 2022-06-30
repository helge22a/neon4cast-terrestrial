library(tidync)
library(dplyr)
#download stacked NOAA
Sys.setenv("AWS_DEFAULT_REGION" = "data",
           "AWS_S3_ENDPOINT" = "ecoforecast.org")

get_stacked_noaa_s3(dir = "/projectnb/dietzelab/ahelgeso/NEFI Summer Course 2022/", site = "BART", averaged = FALSE, s3_region = Sys.getenv("AWS_DEFAULT_REGION"))
noaaStack <- stack_noaa(dir = "/projectnb2/dietzelab/ahelgeso/NEFI Summer Course 2022/drivers/", model = "NOAAGEFS_1hr_stacked")

#download_noaa_(siteID = "BART", interval = "6hr", date = Sys.Date()-2, cycle = "00", dir = "/projectnb/dietzelab/ahelgeso/NEFI Summer Course 2022/")

#filter stacked NOAA for date range
BART <- dplyr::filter(noaaStack, siteID == "BART", time >= as.Date("2021-05-01"))
BART_calibration <- dplyr::filter(BART, time <= as.Date("2021-07-31"))
BART_calibration.avg <- BART_calibration %>% group_by(time) %>% summarize(temp = mean(air_temperature))

K2C <- function(x){
  c = x - 273.15
  return(c)
}
temp.C <- BART_calibration.avg$temp - 273.15
BART_calibration.avg$temp.C <- temp.C
