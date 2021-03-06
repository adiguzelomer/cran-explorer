################################################################################
# Module graph_network
#
# Author: Stefan Schliebs
# Created: 2019-02-08 09:34:27
################################################################################


# Global constants --------------------------------------------------------

# number of rows in the HTML data table showing all packages 
ROWS_PER_PAGE <- 15



# UI of the module --------------------------------------------------------

graph_network_ui <- function(id) {
  ns <- NS(id)
  
  material_card(
    fluidRow(
      column(
        width = 4,
        DT::DTOutput(ns("package_table")),
        style = "font-size: 8pt"
      ),
      column(
        width = 8,
        fluidRow(
          column(
            width = 6,
            # sliderInput(
            #   ns("order"), label = "Order of ego network",
            #   min = 1, max = 10, value = 2,
            #   width = "100%"
            # ),
            style = "font-size: 0.9em"
          ),
          column(
            width = 6,
            switchInput(ns("graph_physics_enabled"), label = "Layout", value = FALSE, size = "mini"),
            style = "padding-top: 10px; text-align: right"
          ),
          column(
            width = 12,
            div(
              class = "graph-loading-bar",
              style = "margin-top: 180px",
              id = ns("loading-bar"),
              div(id = ns("loading-text"), class = "graph-loading-text", "Select a package"),
              div(
                id = ns("loading-bar-background"), class = "graph-loading-bar-background",
                div(id = ns("progress-bar"), class = "graph-progress-bar")
              )
            ),
            div(
              visNetworkOutput(ns("graph"), width = "100%", height = "450px"),
              style = "margin-top: -180px"
            )
          )
        )
      ),
      column(
        width = 12,
        uiOutput(ns("package_details"))
      ),
      column(
        width = 12,
        DT::DTOutput(ns("version_table")),
        style = "font-size: 8pt"
      )
      
    )
  )
}



# Server logic of the module ----------------------------------------------

graph_network <- function(input, output, session, d_pkg_dependencies, d_pkg_details, d_pkg_releases) {
  ns <- session$ns


  # Package table  ----------------------------------------------------------
  
  # data for the table to render
  d_package_table <- reactive({
    d_pkg_dependencies() %>% 
      filter(dependency != "R") %>%
      count(dependency, sort = TRUE) %>% 
      rename(package = dependency, `# refs` = n)
  })
  
  # render prepared package table
  output$package_table <- DT::renderDT({
    d_package_table() %>% 
      DT::datatable(
        options = list(pageLength = ROWS_PER_PAGE, responsive = TRUE, dom = "ftip"),
        selection = list(mode = "single"),
        class = "display compact",
        rownames = FALSE
      )
  })
  
  # pre-select a package to reveal the functionality of the app
  observe({
    req(d_package_table())
    
    # determine the row in the package table that contains the package representing the selected node
    row_index <- which(d_package_table()$package == "png") 

    DT::dataTableProxy("package_table") %>% 
      DT::selectRows(row_index) %>% 
      DT::selectPage(which(input$package_table_rows_all == row_index) %/% ROWS_PER_PAGE + 1)
  })


  # Ego graph ---------------------------------------------------------------

  # create network graph from d_pkg_dependencies()
  g_deps <- reactive({
    req(d_pkg_dependencies())
    
    d_pkg_dependencies() %>% 
      filter(dependency != "R") %>% 
      select(from = package, to = dependency) %>% 
      igraph::graph_from_data_frame(directed = TRUE)
  })
  
  # update center node of the ego network when a new row is selected in the package table 
  center_node <- reactive({
    req(input$package_table_rows_selected)
    
    d_package_table() %>% 
      slice(input$package_table_rows_selected) %>% 
      pull(package)
  })
  
  # ego graph extracted using igraph
  g_ego <- reactive({
    req(g_deps(), center_node())
    # req(g_deps(), input$order, center_node())
    
    # extract ego graph depending on user input
    g <- 
      g_deps() %>% 
      igraph::make_ego_graph(order = 3, nodes = center_node(), mode = "in") %>% 
      # igraph::make_ego_graph(order = input$order, nodes = center_node(), mode = "in") %>% 
      .[[1]]
    print(g)
    
    # set node size proportional to node degree
    node_degree <- igraph::degree(g)
    igraph::V(g)$size <- ifelse(node_degree < 50, 2 * node_degree, 100) + 10
    
    g
  })


  # Layout stop/start functionality -----------------------------------------
  
  # switch on/off network physics engine depending on button state
  observeEvent(input$graph_physics_enabled, {
    visNetworkProxy(ns("graph")) %>% 
      visPhysics(enabled = input$graph_physics_enabled)
  })
  
  
  # Dependency network ------------------------------------------------------

  # javascript function to control progress bar during network layouting
  progress_js_func <- function() {
    glue(
      "function(params) {{",
      "  var maxWidth = 100;",
      "  var minWidth = 20;",
      "  var widthFactor = params.iterations / params.total;",
      "  var width = Math.max(minWidth, maxWidth * widthFactor);",
      "  document.getElementById('{ns('loading-bar')}').style.visibility = 'visible';",
      "  document.getElementById('{ns('progress-bar')}').style.width = width + 'px';",
      "  document.getElementById('{ns('loading-text')}').innerHTML = 'loading - ' + Math.round(widthFactor*100) + '%';",
      "}}"
    )
  }
  
  # javascript function to switch off physics engine after the maximum layout iterations have finished
  stabilised_js_func <- function() {
    glue(
      "function() {{",
      "  document.getElementById('{ns('progress-bar')}').style.width = '100px';",
      "  document.getElementById('{ns('loading-text')}').innerHTML = 'loading - 100%';",
      "  document.getElementById('graph{ns('graph')}').chart.stopSimulation();",
      "  document.getElementById('{ns('loading-bar')}').style.visibility = 'hidden';",
      "}}"
    )
  }

  # render the network graph
  output$graph <- renderVisNetwork({
    # convert igraph into visnetwork graph
    data <- visNetwork::toVisNetworkData(g_ego())
    # browser()
    
    # add node properties:
    # - colorise center node and label 
    # - set label font size proportional to degree of node
    nodes <- 
      data$nodes %>% 
      mutate(
        font.size = 3 * size, 
        color = ifelse(id == isolate(center_node()), "firebrick", "#97C2FC"),
        font.color = ifelse(id == isolate(center_node()), "firebrick", "#343434")
      ) %>% 
      left_join(d_pkg_details() %>% select(id = package, title), by = "id")
    
    # render the network
    visNetwork(
      nodes = nodes, 
      edges = data$edges
    ) %>% 
      
      # use straight edges to improve rendering performance
      visEdges(smooth = FALSE, color = list(opacity = 0.5)) %>%
      # visInteraction(hideEdgesOnDrag = TRUE) %>% 
      
      # configure layouting algorithm
      visPhysics(
        solver = "forceAtlas2Based", 
        timestep = 0.5,
        minVelocity = 1,
        maxVelocity = 30,
        forceAtlas2Based = list(gravitationalConstant = -200, damping = 1),
        stabilization = list(iterations = 200, updateInterval = 10),
        adaptiveTimestep = TRUE
      ) %>%
      
      visOptions(nodesIdSelection = list(enabled = TRUE, style = "margin-bottom: -30px; visibility: hidden")) %>%
      
      # connect custom javascript functions to network events 
      visEvents(
        stabilizationProgress = progress_js_func(),
        stabilizationIterationsDone = stabilised_js_func()
      )
  })
  

  # Network interaction -----------------------------------------------------

  observeEvent(input$graph_selected, {
    req(input$graph_selected)

    # determine the row in the package table that contains the package representing the selected node
    row_index <- which(d_package_table()$package == input$graph_selected) 

    # select the identified row and jump to the page in the table
    DT::dataTableProxy("package_table") %>% 
      DT::selectRows(row_index) %>% 
      DT::selectPage(which(input$package_table_rows_all == row_index) %/% ROWS_PER_PAGE + 1)
  })
  
  
  # Package details ---------------------------------------------------------

  selected_package <- reactive({
    req(center_node())
    
    list(
      details = d_pkg_details() %>% filter(package == center_node()),
      versions = d_pkg_releases() %>% filter(package == center_node())
    )
  })
  
  output$package_details <- renderUI({
    req(selected_package())
    
    tagList(
      hr(),
      h4(selected_package()$details$package),
      h5(selected_package()$details$title),
      p(selected_package()$details$description),
      h5("Publication History", style = "margin-top: 15px")
    )
  })
  
  output$version_table <- DT::renderDT({
    req(selected_package())
    
    selected_package()$versions %>% 
      select(-package) %>% 
      arrange(desc(published)) %>% 
      DT::datatable(
        options = list(pageLength = ROWS_PER_PAGE, responsive = TRUE, dom = "t"),
        selection = "single",
        class = "display compact",
        rownames = FALSE
      )
  })
  
}