#This is the function file. It is called directly from the analysis file.
packageHandler <- function(packages, update_packages = TRUE, install_packages = TRUE) {
	bad_packages <- list()
	for (package in packages) {
		if (install_packages) {
			tryCatch({
				find.package(package)
			}, error = function(e) {
				if (package == 'CausalImpact') {
					packageHandler('devtools', update_packages, install_packages)
					CI_desc <- do.call(rbind, strsplit(readLines('https://raw.githubusercontent.com/google/CausalImpact/master/DESCRIPTION'), split = ': '))
					rownames(CI_desc) <- CI_desc[, 1]
					CI_desc <- as.list(CI_desc[c('Package', 'Date', 'Copyright', 'Version', 'License', 'Imports', 'Depends', 'Suggests'), -1], rownames(CI_desc))
					CI_desc[c('Imports', 'Depends', 'Suggests')] <- lapply(CI_desc[c('Imports', 'Depends', 'Suggests')], FUN = function(string) {strsplit(string, split = ', ')[[1]]})
					packageHandler(c(CI_desc$Imports, CI_desc$Depends, CI_desc$Suggests), update_packages, install_packages)
					devtools::install_github('google/CausalImpact')
				} else {
					if (package %in% available.packages()) {
						install.packages(package, repos = 'http://cran.rstudio.com/')
					} else {
						bad_packages <<- append(bad_packages, package)
					}
				}
			}, warning = function(w) {
				paste(w, 'Shouldn\'t be here.')
			}, finally = {
				if (update_packages) {
					if (package == 'CausalImpact') {
						CI_desc <- do.call(rbind, strsplit(readLines('https://raw.githubusercontent.com/google/CausalImpact/master/DESCRIPTION'), split = ': '))
						rownames(CI_desc) <- CI_desc[, 1]
						CI_desc <- as.list(CI_desc[c('Package', 'Date', 'Copyright', 'Version', 'License', 'Imports', 'Depends', 'Suggests'), -1], rownames(CI_desc))
						if (packageVersion('CausalImpact') != CI_desc$Version) {
							devtools::install_github('google/CausalImpact')
						}
					} else {
						update.packages(package, repos = 'http://cran.rstudio.com/')
					}	
				}
			})
		}
	}
	if (length(bad_packages) > 0) {
		if (length(bad_packages) == 1) {
			stop(paste('Package', paste('"', bad_packages, '"', sep = ''), 'is not available for', paste(version$version.string, '.', sep = '')))
		} else {
			stop(paste('Packages', paste(lapply(bad_packages, function(bad_package) {paste('"', bad_package, '"', sep = '')}), collapse = ', '), 'are not available for', paste(version$version.string, '.', sep = '')))
		}
	}
	return()
}

#Rearrange date to YYYY-MM-DD format.
formatDate <- function(time_points) {
	time_points <- as_date(time_points)
	time_points <- as.Date(time_points, format = '%Y-%m-%d')
	return(time_points)
}

splitGroup <- function(ungrouped_data, group_name, group, date_name, start_date, end_date, no_filter = NULL) {
	ds <- ungrouped_data[ungrouped_data[, group_name] == group, ]
	ds <- ds[, colSums(is.na(ds)) == 0]
	ds <- ds[match(start_date, ds[, date_name]):match(end_date, ds[, date_name]), ]
	ds <- cbind(ds[, colnames(ds) %in% no_filter], filterSparse(ds[, !(colnames(ds) %in% no_filter)]))
	return(ds)
}

#Log-transform the data.
logTransform <- function(prelog_data, no_log = NULL) {
	prelog_data[prelog_data == 0] <- 0.5
	prelog_data[, !(colnames(prelog_data) %in% no_log)] <- log(prelog_data[, !(colnames(prelog_data) %in% no_log)])
	return(prelog_data)
}

filterSparse <- function(dataset, threshold = 5) {
	return(dataset[, colMeans(dataset) > threshold, drop = FALSE])
}

#Used to adjust the Brazil data for a code shift in 2008.
getTrend <- function(covar_vector, data) {
	new_data <- data
	new_data[c('bs1', 'bs2', 'bs3', 'bs4')] <- 0
	new_data$month_i <- as.factor(1)
	trend <- predict(glm(covar_vector~month_i + ., family = 'gaussian', data = data), type = 'response', newdata = new_data) #month_i is first to be the reference.
	names(trend) <- NULL
	return(trend)
}

makeCovars <- function(ds_group, code_change, intervention_date, time_points) {
	if (code_change) {
		#Eliminates effects from 2008 coding change
		covars <- ds_group[, 4:ncol(ds_group)]
		month_i <- as.factor(as.numeric(format(time_points, '%m')))
		spline <- setNames(as.data.frame(bs(1:nrow(covars), knots = 5, degree = 3)), c('bs1', 'bs2', 'bs3', 'bs4'))
		year_2008 <- numeric(nrow(covars))
		year_2008[1:nrow(covars) >= match(as.Date('2008-01-01'), time_points)] <- 1
		data <- cbind.data.frame(year_2008, spline, month_i)
		trend <- lapply(covars, getTrend, data = data)
		covars <- covars - trend
	} else {
		covars <- ds_group[, 4:ncol(ds_group), drop = FALSE]
	}
	if (intervention_date > as.Date('2009-09-01')) {
		covars$pandemic <- ifelse(time_points == '2009-08-01', 1, ifelse(time_points == '2009-09-01', 1, 0))
	}
	covars <- as.data.frame(lapply(covars[, apply(covars, 2, var) != 0, drop = FALSE], scale), check.names = FALSE)
	return(covars)
}

#Combine the outcome and covariates.
makeTimeSeries <- function(group, outcome, covars, time_points) {
	return(zoo(cbind(outcome = outcome[, group], covars[[group]]), time_points))
}

impactExtract <- function(impact) {
	burn <- SuggestBurn(0.1, impact$model$bsts.model)
	
	#Posteriors
	state_samples <- rowSums(aperm(impact$model$bsts.model$state.contributions[-(1:burn), , , drop = FALSE], c(1, 3, 2)), dims = 2)
	sigma_obs <- impact$model$bsts.model$sigma.obs[-(1:burn)]
	
	#Sample from posterior predictive density over data
	obs_noise_samples <- matrix(rnorm(prod(dim(state_samples)), 0, sigma_obs), nrow = dim(state_samples)[1])
	y_samples <- state_samples + obs_noise_samples
	
	inclusion_probs <- sort(colMeans(impact$model$bsts.model$coefficients != 0))
	return(list(y_samples = y_samples, series = impact$series, inclusion_probs = inclusion_probs))
}

#Main analysis function.
doCausalImpact <- function(zoo_data, intervention_date, time_points, n_seasons = NULL, n_pred = 5, n_iter = 10000, trend = FALSE) {
	if (is.null(n_seasons) || is.na(n_seasons)) {
		n_seasons <- length(unique(month(time(zoo_data)))) #number of months
	}
	y <- zoo_data[, 1]
	y[time_points >= as.Date(intervention_date)] <- NA
	sd_limit <- sd(y)
	sd <- sd(y, na.rm = TRUE)
	mean <- mean(y, na.rm = TRUE)
	
	post_period_response <- zoo_data[, 1]
	post_period_response <- as.vector(post_period_response[time_points >= as.Date(intervention_date)])
	
	sigma_prior_guess <- 1e-6
	prior_sample_size <- 1e6
	ss <- NA
	ss <- AddSeasonal(list(), y, nseasons = n_seasons, sigma.prior = SdPrior(sigma.guess = sigma_prior_guess, sample.size = prior_sample_size, upper.limit = sd_limit))
	ss <- AddLocalLevel(ss, y, sigma.prior = SdPrior(sigma.guess = sigma_prior_guess, sample.size = prior_sample_size, upper.limit = sd_limit), initial.state.prior = NormalPrior(mean, sd))
	
	if (trend) {
		x <- zoo_data[, -1] #Removes outcome column from dataset
		bsts_model <- bsts(y~., data = x, state.specification = ss, prior.inclusion.probabilities = c(1.0, 1.0), niter = n_iter, ping = 0, seed = 1)	
	} else {
		x <- zoo_data[, -1] #Removes outcome column from dataset
		regression_prior_df <- 50
		exp_r2 <- 0.8
		bsts_model <- bsts(y~., data = x, state.specification = ss, niter = n_iter, expected.model.size = n_pred, prior.df = regression_prior_df, expected.r2 = exp_r2, ping = 0, seed = 1)
	}
	impact <- CausalImpact(bsts.model = bsts_model, post.period.response = post_period_response)
	colnames(impact$model$bsts.model$coefficients)[-1] <- names(zoo_data)[-1]
	impact_extract <- impactExtract(impact)
	return(impact_extract)
}

#Save inclusion probabilities.
inclusionProb <- function(impact) {
	return(impact$inclusion_probs)
}

#Estimate the rate ratios during the evaluation period and return to the original scale of the data.
rrPredQuantiles <- function(impact, denom_data = NULL, mean, sd, eval_period, post_period, trend = FALSE) {
	if (trend) {
		pred_samples <- exp(denom_data) * t(exp(impact$y_samples * sd + mean))
	} else {
		pred_samples <- t(exp(impact$y_samples * sd + mean))	
	}
	
	pred <- t(apply(pred_samples, 1, quantile, probs = c(0.025, 0.5, 0.975), na.rm = TRUE))
	eval_indices <- match(eval_period[1], index(impact$series$response)):match(eval_period[2], index(impact$series$response))
	
	pred_eval_sum <- colSums(pred_samples[eval_indices, ])
	
	if (trend) {
		eval_obs <- sum((exp(denom_data) * exp(impact$series$response * sd + mean))[eval_indices])
	} else {
		eval_obs <- sum(exp((impact$series$response[eval_indices] * sd + mean)))	
	}
	
	eval_rr_sum <- eval_obs/pred_eval_sum
	rr <- quantile(eval_rr_sum, probs = c(0.025, 0.5, 0.975))
	names(rr) <- c('Lower CI', 'Point Estimate', 'Upper CI')
	mean_rr <- mean(eval_rr_sum)
	
	plot_rr_start <- post_period[1] %m-% months(24)
	roll_rr_indices <- match(plot_rr_start, index(impact$series$response)):match(eval_period[2], index(impact$series$response))
	if (trend) {
		obs_full <- exp(denom_data) * exp(impact$series$response * sd + mean)
	} else {
		obs_full <- exp(impact$series$response * sd + mean)
	}
	roll_sum_pred <- roll_sum(pred_samples[roll_rr_indices, ], 12)
	roll_sum_obs <- roll_sum(obs_full[roll_rr_indices], 12)
	roll_rr_est <- as.data.frame(sweep(1 / roll_sum_pred, 1, as.vector(roll_sum_obs), `*`))
	roll_rr <- t(apply(roll_rr_est, 1, quantile, probs = c(0.025, 0.5, 0.975), na.rm = TRUE))
	quantiles <- list(pred_samples = pred_samples, pred = pred, rr = rr, roll_rr = roll_rr, mean_rr = mean_rr)
	return(quantiles)
}

getPred <- function(quantiles) {
	return(quantiles$pred)
}

getRR <- function(quantiles) {
	return(quantiles$rr)
}

makeInterval <- function(point_estimate, upper_interval, lower_interval, digits = 2) {
	return(paste(round(as.numeric(point_estimate), digits), ' (', round(as.numeric(lower_interval), digits), ', ', round(as.numeric(upper_interval), digits), ')', sep = ''))
}

#Plot predictions.
plotPred <- function(pred_quantiles, time_points, post_period, ylim, outcome_plot, title = NULL, sensitivity_pred_quantiles = NULL, sensitivity_title = 'Sensitivity Plots', plot_sensitivity = FALSE) {
	
	post_period_start <- which(time_points == post_period[1]) 
	post_period_end <- which(time_points == post_period[2])
	post_dates <- c(time_points[post_period_start:post_period_end], rev(time_points[post_period_start:post_period_end]))
	
	if (!plot_sensitivity) {
		pred_plot <- ggplot() + 
			geom_polygon(data = data.frame(time = c(post_dates, rev(post_dates)), pred_bound = c(pred_quantiles[which(time_points %in% post_dates), 3], rev(pred_quantiles[which(time_points %in% post_dates), 1]))), aes_string(x = 'time', y = 'pred_bound'), alpha = 0.3) +
			geom_line(data = data.frame(time = time_points, outcome = outcome_plot), aes_string(x = 'time', y = 'outcome')) +
			geom_line(data = data.frame(time = time_points, pred_outcome = pred_quantiles[, 2]), aes_string(x = 'time', y = 'pred_outcome'), linetype = 'dashed', color = 'gray') + 
			labs(x = 'Time', y = 'Number of Cases') + 
			ggtitle(title) + 
			theme_bw() +
			theme(plot.title = element_text(hjust = 0.5), panel.grid.major = element_blank(), panel.grid.minor = element_blank())
		return(pred_plot)
	} else if (!is.null(sensitivity_pred_quantiles)) {
		sensitivity_df <- data.frame('Outcome' = outcome_plot, 'Estimate' = pred_quantiles[, 2], 'Sensitivity 1' = sensitivity_pred_quantiles[[1]][, 2], 'Sensitivity 2' = sensitivity_pred_quantiles[[2]][, 2], 'Sensitivity 3' = sensitivity_pred_quantiles[[3]][, 2], check.names = FALSE)
		sensitivity_bound <- data.frame('Sensitivity 1' = c(sensitivity_pred_quantiles[[1]][which(time_points %in% post_dates), 3], rev(sensitivity_pred_quantiles[[1]][which(time_points %in% post_dates), 1])), 'Sensitivity 2' = c(sensitivity_pred_quantiles[[2]][which(time_points %in% post_dates), 3], rev(sensitivity_pred_quantiles[[2]][which(time_points %in% post_dates), 1])), 'Sensitivity 3' = c(sensitivity_pred_quantiles[[3]][which(time_points %in% post_dates), 3], rev(sensitivity_pred_quantiles[[3]][which(time_points %in% post_dates), 1])), check.names = FALSE)
		
		pred_plot <- ggplot() + 
			geom_polygon(data = melt(sensitivity_bound, id.vars = NULL), aes_string(x = rep(post_dates, ncol(sensitivity_bound)), y = 'value', fill = 'variable'), alpha = 0.3) +
			geom_line(data = melt(sensitivity_df, id.vars = NULL), aes_string(x = rep(time_points, ncol(sensitivity_df)), y = 'value', color = 'variable')) +
			scale_colour_manual(values = c('black', 'gray', 'red', 'green', 'blue')) +
			scale_fill_hue(guide = 'none') +
			labs(x = 'Time', y = 'Number of Cases') + 
			ggtitle(sensitivity_title) + 
			theme_bw() +
			theme(legend.title = element_blank(), legend.position = c(0, 1), legend.justification = c(0, 1), legend.background = element_rect(colour = NA, fill = 'transparent'), plot.title = element_text(hjust = 0.5), panel.grid.major = element_blank(), panel.grid.minor = element_blank())
		return(pred_plot)
	}
}

#Sensitivity analysis by dropping the top weighted covariates. 
weightSensitivityAnalysis <- function(group, covars, ds, impact, time_points, intervention_date, n_seasons, outcome, mean = NULL, sd = NULL, eval_period = NULL, post_period = NULL) {
	par(mar = c(5, 4, 1, 2) + 0.1)
	covar_df <- covars[[group]]
	df <- ds[[group]]
	
	incl_prob <- impact[[group]]$inclusion_probs
	max_var <- names(incl_prob)[length(incl_prob)]
	max_prob <- incl_prob[length(incl_prob)]
	sensitivity_analysis <- vector('list', 3)
	
	for (i in 1:3) {
		df <- df[, names(df) != max_var]
		covar_df <- covar_df[, names(covar_df) != max_var]
		#Combine covars, outcome, date
		zoo_data <- zoo(cbind(outcome = outcome[, group], covar_df), time_points)
		impact <- doCausalImpact(zoo_data, intervention_date, time_points, n_seasons)
		
		sensitivity_analysis[[i]] <- list(removed_var = max_var, removed_prob = max_prob)
		if (!is.null(mean) && !is.null(sd) && !is.null(eval_period) && !is.null(post_period)) {
			quantiles <- rrPredQuantiles(impact = impact, mean = mean[group], sd = sd[group], eval_period = eval_period, post_period = post_period)
			sensitivity_analysis[[i]]$rr <- quantiles$rr
			sensitivity_analysis[[i]]$pred <- quantiles$pred
		}
		
		incl_prob <- impact$inclusion_probs
		max_var <- names(incl_prob)[length(incl_prob)]
		max_prob <- incl_prob[length(incl_prob)]
	}
	return(sensitivity_analysis)
}

predSensitivityAnalysis <- function(group, ds, zoo_data, denom_name, outcome_mean, outcome_sd, intervention_date, eval_period, post_period, time_points, n_seasons , n_pred) {
	impact <- doCausalImpact(zoo_data[[group]], intervention_date, time_points, n_seasons, n_pred = n_pred)
	quantiles <- lapply(group, FUN = function(group) {rrPredQuantiles(impact = impact, denom_data = ds[[group]][, denom_name], mean = outcome_mean[group], sd = outcome_sd[group], eval_period = eval_period, post_period = post_period)})
	rr_mean <- t(sapply(quantiles, getRR))
	return(rr_mean)
}

sensitivityTable <- function(group, sensitivity_analysis, original_rr = NULL) {
	top_controls <- lapply(1:length(sensitivity_analysis[[group]]), FUN = function(i) {
		top_control <- c(sensitivity_analysis[[group]][[i]]$removed_var, sensitivity_analysis[[group]][[i]]$removed_prob, sensitivity_analysis[[group]][[i]]$rr)
		names(top_control) <- c(paste('Top Control', i), paste('Inclusion Probability of Control', i), paste(names(sensitivity_analysis[[group]][[i]]$rr), i))
		return(top_control)
	})
	sensitivity_table <- c(original_rr[group, ], c(top_controls, recursive = TRUE))
	return(sensitivity_table)
}