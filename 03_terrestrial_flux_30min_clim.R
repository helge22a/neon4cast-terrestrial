print(paste0("Running Creating 30-minute Terrestrial Historical Means Forecasts at ", Sys.time()))

pecan_flux_uncertainty <- "../pecan/modules/uncertainty/R/flux_uncertainty.R"

source(pecan_flux_uncertainty)

if(!require(prov)){
  devtools::install_github("https://github.com/cboettig/prov")
}

library(ncdf4)
library(tidyverse)
library(lubridate)
library(rjags)
library(tidybayes)
library(modelr)
library(aws.s3)
library(prov)
library(EFIstandards)
library(EML)
library(jsonlite)

set.seed(42)

ne = 200 ## number of ensemble members

team_list <- list(list(individualName = list(givenName = "Mike",  surName ="Dietze"),
                       id = "https://orcid.org/0000-0002-2324-2518"),
                  list(individualName = list(givenName = "Quinn", surName = "Thomas"), 
                       id = "https://orcid.org/0000-0003-1282-7825")
)

team_name <- "climatology"
forecast_project_id <- "efi_hist"

download.file("https://data.ecoforecast.org/targets/terrestrial_30min/terrestrial_30min-targets.csv.gz",
              "terrestrial_30min-targets.csv.gz")

terrestrial_targets <- read_csv("terrestrial_30min-targets.csv.gz", guess_max = 10000, col_types = cols(
  time = col_datetime(format = ""),
  siteID = col_character(),
  nee = col_double(),
  le = col_double(),
  nee_sd_intercept = col_double(),
  nee_sd_slopeP = col_double(),
  nee_sd_slopeN = col_double(),
  le_sd_intercept = col_double(),
  le_sd_slopeP = col_double(),
  le_sd_slopeN = col_double(),
))

sites <- read_csv("https://raw.githubusercontent.com/eco4cast/neon4cast-terrestrial/master/Terrestrial_NEON_Field_Site_Metadata_20210928.csv")
site_names <- sites$field_site_id

start_forecast <- as.POSIXct(Sys.Date(),tz="UTC")
fx_time <- seq(start_forecast, start_forecast + days(35), by = "30 min")

nee_fx = le_fx = array(NA, dim=c(length(fx_time),length(site_names),ne)) ## dimensions: time, space, ensemble

## Forecast by site
for(s in 1:length(site_names)){
  
  site_data_var <- terrestrial_targets %>%
    filter(siteID == site_names[s])
  
  max_time <- max(site_data_var$time) + days(1)
  
  
  min_time <- min(which(!is.na(site_data_var$nee)))
  # This is key here - I added 16 days on the end of the data for the forecast period
  
  full_time <- tibble(time = seq(site_data_var$time[min_time], max(site_data_var$time), by = "30 min"))
  
  site_data_var <- left_join(full_time, site_data_var) %>% 
    filter(month(time) == month(max_time))  ## grab all historical data for this month
  
  ############ NEE  #############
  
  #Full time series with gaps
  y_wgaps <- site_data_var$nee
  time <- c(site_data_var$time)
  #Remove gaps
  t_nogaps <- time[!is.na(y_wgaps)]
  y_nogaps <- y_wgaps[!is.na(y_wgaps)]

  ## check that we can calculate mean diurnal cycle
  htod = hour(t_nogaps) + minute(t_nogaps)/60  ## historical time of day
  nee_diurnal = tapply(y_nogaps,htod,mean)
  n_diurnal = tapply(y_nogaps,htod,length)
#  plot(nee_diurnal,main=site_names[s])
  
  ## forecast
  ftod = hour(fx_time) + minute(fx_time)/60
  for(i in 1:48){
    tod = (i-1)/2
    window = 0.25
    hindex = which(abs(htod - tod) < window) ## indices in historical data to resample
    while(length(hindex) < 10){
      window = window + 0.5
      hindex = which(abs(htod - tod) < window) ## if no data at that time, look at adjacent times
      #print(window)
    }
    findex = which(ftod == tod) ## columns in fx to fill in
    for(j in findex){
      nee_fx[j,s,] = y_nogaps[sample(hindex,ne,replace=TRUE)]
    }
  }

  ############ Latent heat ############
  
  #Full time series with gaps
  y_wgaps <- site_data_var$le
  #Remove gaps
  t_nogaps <- time[!is.na(y_wgaps)]
  y_nogaps <- y_wgaps[!is.na(y_wgaps)]

  htod = hour(t_nogaps) + minute(t_nogaps)/60  ## historical time of day
  for(i in 1:48){
    tod = (i-1)/2
    window = 0.25
    hindex = which(abs(htod - tod) < window) ## indices in historical data to resample
    while(length(hindex) < 10){
      window = window + 0.5
      hindex = which(abs(htod - tod) < window) ## if no data at that time, look at adjacent times
      print(window)
    }
    findex = which(ftod == tod) ## columns in fx to fill in
    for(j in findex){
      le_fx[j,s,] = y_nogaps[sample(hindex,ne,replace=TRUE)]
    }
  }
} ## end loop over sites

## Set dimensions
timedim <- ncdim_def("time",   ## dimension name
                     units = paste('seconds since',fx_time[1]),
                     ## size of timestep, with units and start date
                     vals = as.numeric(fx_time - fx_time[1]),
                     ## sequence of values that defines the dimension.
                     longname = 'time')
## descriptive name

sitedim <- ncdim_def("site",
                     units="",
                     vals=1:length(site_names),
                     longname = "NEON siteID")

ensdim <- ncdim_def("ensemble",             
                    units = "",
                    vals = seq_len(ne),       
                    longname = 'ensemble member') 

nchardim <- ncdim_def("nchar",units="",1:4,create_dimvar=FALSE)

## quick check that units are valid
udunits2::ud.is.parseable(timedim$units)
udunits2::ud.is.parseable(sitedim$units)
udunits2::ud.is.parseable(ensdim$units)

fillvalue <- 1e32  ## missing data value

#Define variables
def_list <- list()
def_list[[1]] <- ncvar_def(name =  "nee",
                           units = "umol CO2 m-2 s-1",
                           dim = list(timedim, sitedim, ensdim),
                           missval = fillvalue,
                           longname = 'net ecosystem exchange of CO2',
                           prec="double")
def_list[[2]] <- ncvar_def(name =  "le",
                           units = "W m-2",
                           dim = list(timedim, sitedim, ensdim),
                           missval = fillvalue,
                           longname = 'latent heat flux',
                           prec="double")
def_list[[3]] <- ncvar_def(name = "siteID",
                           units="",
                           dim = list(nchardim,sitedim),
                           longname = "NEON site codes",
                           prec="char")

ncfname <- paste0("terrestrial_30min-",as_date(start_forecast),"-",team_name,".nc")
ncout <- nc_create(ncfname,def_list,force_v4=T)
ncvar_put(ncout,def_list[[1]] , nee_fx)
ncvar_put(ncout,def_list[[2]] , le_fx)
ncvar_put(ncout,def_list[[3]] , site_names)

## Global attributes (metadata)
curr_time <- with_tz(Sys.time(), "UTC")
ncatt_put(ncout,0,"forecast_project_id", as.character(forecast_project_id), 
          prec =  "text")
ncatt_put(ncout,0,"forecast_model_id",as.character(forecast_project_id), 
          prec =  "text")
ncatt_put(ncout,0,"forecast_iteration_id",as.character(curr_time), 
          prec =  "text")

nc_close(ncout)   ## make sure to close the file

# Generate metadata
forecast_issue_time <- as_date(curr_time)
forecast_iteration_id <- start_forecast
forecast_model_id <- team_name

source("generate_metadata.R")
meta_data_filename <- generate_metadata(forecast_file =  ncfname,
                                        metadata_yaml = "metadata_30min.yml",
                                        forecast_issue_time = as_date(with_tz(Sys.time(), "UTC")),
                                        forecast_iteration_id = start_forecast,
                                        forecast_file_name_base = strsplit(ncfname,".",fixed=TRUE)[[1]][1],
                                        start_time = fx_time[1],
                                        stop_time = last(fx_time))
neon4cast::submit(forecast_file = ncfname, 
                  metadata = meta_data_filename, 
                  ask = FALSE)

unlink(ncfname)
unlink(meta_data_filename)



